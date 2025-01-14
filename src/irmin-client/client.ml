open Irmin_server_internal
open Lwt.Syntax
open Lwt.Infix
include Client_intf

module Make (I : IO) (Codec : Conn.Codec.S) (Store : Irmin.Generic_key.S) =
struct
  module C = Command.Make (I) (Codec) (Store)
  module St = Store
  open C
  module Hash = Store.Hash
  module Path = Store.Path
  module Metadata = Store.Metadata
  module IO = I

  module Private = struct
    module Store = C.Store
    module Tree = C.Tree
  end

  module Schema = C.Store.Schema

  module Info = struct
    include C.Store.Schema.Info

    let init = v

    let v ?author fmt =
      Fmt.kstr
        (fun message () ->
          let date = Int64.of_float (Unix.gettimeofday ()) in
          init ?author ~message date)
        fmt
  end

  type hash = Store.hash
  type contents = Store.contents
  type branch = Store.branch
  type path = Store.path
  type step = Store.step
  type commit = C.Commit.t
  type slice = St.slice
  type stats = Stats.t
  type metadata = St.metadata

  let stats_t = Stats.t
  let slice_t = St.slice_t

  type conf = { uri : Uri.t; client : addr; batch_size : int }
  type t = { conf : conf; mutable conn : Conn.t }

  let uri t = t.conf.uri

  type batch =
    (Store.path
    * [ `Contents of
        [ `Hash of Store.Hash.t | `Value of Store.contents ]
        * Store.metadata option
      | `Tree of Tree.t ]
      option)
    list
  [@@deriving irmin]

  type tree = t * Private.Tree.t * batch

  let conf ?(batch_size = 32) ?(tls = false) ~uri () =
    let scheme = Uri.scheme uri |> Option.value ~default:"tcp" in
    let addr = Uri.host_with_default ~default:"127.0.0.1" uri in
    let client =
      match String.lowercase_ascii scheme with
      | "unix" -> `Unix_domain_socket (`File (Uri.path uri))
      | "tcp" ->
          let ip = Unix.gethostbyname addr in
          let port = Uri.port uri |> Option.value ~default:9181 in
          let ip =
            ip.h_addr_list.(0) |> Unix.string_of_inet_addr
            |> Ipaddr.of_string_exn
          in
          if not tls then `TCP (`IP ip, `Port port)
          else `TLS (`Hostname addr, `IP ip, `Port port)
      | x -> invalid_arg ("Unknown client scheme: " ^ x)
    in
    { client; batch_size; uri }

  let connect' ?(ctx = Lazy.force IO.default_ctx) conf =
    let* flow, ic, oc = IO.connect ~ctx conf.client in
    let conn = Conn.v flow ic oc in
    let+ () = Conn.Handshake.V1.send (module Private.Store) conn in
    { conf; conn }

  let connect ?ctx ?batch_size ?tls ~uri () =
    let client = conf ?batch_size ?tls ~uri () in
    connect' ?ctx client

  let dup client = connect' client.conf
  let close t = IO.close (t.conn.ic, t.conn.oc)

  let handle_disconnect t f =
    Lwt.catch f (function
      | End_of_file ->
          Logs.info (fun l -> l "Reconnecting to server");
          let* conn = connect' t.conf in
          t.conn <- conn.conn;
          f ()
      | exn -> raise exn)
    [@@inline]

  let send_command_header t (module Cmd : C.CMD) =
    let header = Conn.Request.v_header ~command:Cmd.name in
    Conn.Request.write_header t.conn header

  let recv (t : t) name ty =
    let* res = Conn.Response.read_header t.conn in
    Conn.Response.get_error t.conn.buffer t.conn res >>= function
    | Some err ->
        Logs.err (fun l -> l "Request error: command=%s, error=%s" name err);
        Lwt.return_error (`Msg err)
    | None ->
        let+ x = Conn.read ~buffer:t.conn.buffer t.conn ty in
        Logs.debug (fun l -> l "Completed request: command=%s" name);
        x

  let request (t : t) (type x y)
      (module Cmd : C.CMD with type Res.t = x and type Req.t = y) (a : y) =
    let name = Cmd.name in
    Logs.debug (fun l -> l "Starting request: command=%s" name);
    handle_disconnect t (fun () ->
        let* () = send_command_header t (module Cmd) in
        let* () = Conn.write t.conn Cmd.Req.t a in
        let* () = IO.flush t.conn.oc in
        recv t name Cmd.Res.t)

  let recv_commit_diff (t : t) =
    Lwt.catch
      (fun () ->
        Conn.read ~buffer:t.conn.buffer t.conn (Irmin.Diff.t Commit.t)
        >>= function
        | Ok x -> Lwt.return_some x
        | Error e ->
            Logs.err (fun l -> l "Watch error: %s" (Error.to_string e));
            Lwt.return_none)
      (fun _ -> Lwt.return_none)

  module Cache = struct
    module Contents = Irmin.Backend.Lru.Make (struct
      type t = St.Hash.t

      let hash = Hashtbl.hash
      let equal = Irmin.Type.(unstage (equal St.Hash.t))
    end)

    module Commit = Irmin.Backend.Lru.Make (struct
      type t = St.commit_key

      let hash = Hashtbl.hash
      let equal = Irmin.Type.(unstage (equal St.commit_key_t))
    end)

    let commit : commit Commit.t = Commit.create 64
    let contents : contents Contents.t = Contents.create 64
  end

  let stats t = request t (module Commands.Stats) ()
  let ping t = request t (module Commands.Ping) ()
  let export ?depth t = request t (module Commands.Export) depth
  let import t slice = request t (module Commands.Import) slice
  let unwatch t = request t (module Commands.Unwatch) ()

  let watch f t =
    request t (module Commands.Watch) () >>= function
    | Error e -> Lwt.return_error e
    | Ok () -> (
        let rec loop () =
          recv_commit_diff t >>= function
          | Some diff -> (
              f diff >>= function
              | Ok `Continue -> loop ()
              | Ok `Stop -> Lwt.return_ok ()
              | Error e -> Lwt.return_error e)
          | None ->
              let* () = Lwt_unix.sleep 0.25 in
              loop ()
        in
        loop () >>= function
        | Ok () -> unwatch t
        | Error e ->
            let* _ = unwatch t in
            Lwt.return_error e)

  module Branch = struct
    include Store.Branch

    let set_current t (branch : Store.branch) =
      request t (module Commands.Set_current_branch) branch

    let get_current t = request t (module Commands.Get_current_branch) ()
    let get ?branch t = request t (module Commands.Branch_head) branch

    let set ?branch t commit =
      request t (module Commands.Branch_set_head) (branch, commit)

    let remove t branch = request t (module Commands.Branch_remove) branch
  end

  module Contents = struct
    include St.Contents

    let of_hash t hash =
      if Cache.Contents.mem Cache.contents hash then
        Lwt.return_ok (Some (Cache.Contents.find Cache.contents hash))
      else request t (module Commands.Contents_of_hash) hash

    let exists' t contents =
      let hash = hash contents in
      if Cache.Contents.mem Cache.contents hash then Lwt.return_ok (hash, true)
      else
        let* res = request t (module Commands.Contents_exists) hash in
        match res with
        | Ok true ->
            Cache.Contents.add Cache.contents hash contents;
            Lwt.return_ok (hash, true)
        | x -> Lwt.return (Result.map (fun y -> (hash, y)) x)

    let exists t contents = exists' t contents >|= Result.map snd

    let save t contents =
      let hash = hash contents in
      if Cache.Contents.mem Cache.contents hash then Lwt.return_ok hash
      else request t (module Commands.Contents_save) contents
  end

  module Tree = struct
    type store = t
    type key = St.Tree.kinded_key

    let key_t = St.Tree.kinded_key_t

    let rec build (t : store) ?tree b : tree Error.result Lwt.t =
      let tree =
        match tree with
        | Some tree -> tree
        | None ->
            let _, tree, _ = empty t in
            tree
      in
      match b with
      | [] -> Lwt.return_ok (t, tree, [])
      | b -> batch_update (t, tree, b) []

    and batch_update (((t : store), tree, batch) : tree) l =
      wrap t
        (request t
           (module Commands.Tree.Batch_update)
           (tree, List.rev_append batch (List.rev l)))

    and wrap ?(batch = []) store tree =
      let* tree in
      Lwt.return (Result.map (fun tree -> (store, tree, batch)) tree)

    and empty (t : store) : tree = (t, Tree.Local (`Tree []), [])

    module Batch = struct
      let path_equal = Irmin.Type.(unstage (equal Path.t))

      let find b k =
        let l =
          List.filter_map
            (fun (a, b) ->
              match b with
              | Some (`Contents _ as x) when path_equal k a -> Some x
              | _ -> None)
            b
        in
        match l with [] -> None | h :: _ -> Some h

      let find_tree b k =
        let l =
          List.filter_map
            (fun (a, b) ->
              match b with
              | Some (`Tree _ as x) when path_equal k a -> Some x
              | _ -> None)
            b
        in
        match l with [] -> None | h :: _ -> Some h

      let mem b k =
        List.exists
          (fun (a, b) ->
            match b with Some (`Contents _) -> path_equal k a | _ -> false)
          b

      let mem_tree b k =
        List.exists
          (fun (a, b) ->
            match b with Some (`Tree _) -> path_equal k a | _ -> false)
          b

      let remove b k = (k, None) :: b

      let add batch path ?metadata value =
        (path, Some (`Contents (`Value value, metadata))) :: batch

      let add_hash batch path ?metadata hash =
        (path, Some (`Contents (`Hash hash, metadata))) :: batch

      let add_tree batch path (_, tree, batch') =
        ((path, Some (`Tree tree)) :: batch') @ batch
    end

    let split t = t
    let v t ?(batch = []) tr = (t, tr, batch)
    let of_key t k = (t, Private.Tree.Key k, [])

    let map_tree tree f =
      Result.map (fun (_, tree, _) -> f tree) tree |> function
      | Ok x -> (
          x >>= function
          | Ok x -> Lwt.return_ok x
          | Error e -> Lwt.return_error e)
      | Error e -> Lwt.return_error e

    let clear (t, tree, batch) =
      let* tree = build t ~tree batch in
      map_tree tree (fun tree -> request t (module Commands.Tree.Clear) tree)

    let key (t, tree, batch) =
      let* tree = build t ~tree batch in
      map_tree tree (fun tree -> request t (module Commands.Tree.Key) tree)

    let add' (t, tree, batch) path value =
      wrap ~batch t (request t (module Commands.Tree.Add) (tree, path, value))

    let add ((t, tree, batch) : tree) path ?metadata value =
      let hash = St.Contents.hash value in
      let exists = Cache.Contents.mem Cache.contents hash in
      let batch =
        if exists then Batch.add_hash batch ?metadata path hash
        else Batch.add batch ?metadata path value
      in
      if List.length batch > t.conf.batch_size then build t ~tree batch
      else Lwt.return_ok (t, tree, batch)

    let add_tree ((t, tree, batch) : tree) path tr =
      let batch = Batch.add_tree batch path tr in
      if List.length batch > t.conf.batch_size then build t ~tree batch
      else Lwt.return_ok (t, tree, batch)

    let add_tree' (t, tree, batch) path (_, tr, batch') =
      wrap ~batch:(batch @ batch') t
        (request t (module Commands.Tree.Add_tree) (tree, path, tr))

    let find ((t, tree, batch) : tree) path : contents option Error.result Lwt.t
        =
      let x = Batch.find batch path in
      match x with
      | Some (`Contents (`Value x, _)) -> Lwt.return_ok (Some x)
      | Some (`Contents (`Hash x, _)) -> Contents.of_hash t x
      | _ -> request t (module Commands.Tree.Find) (tree, path)

    let find_tree ((t, tree, batch) : tree) path :
        tree option Error.result Lwt.t =
      let x = Batch.find_tree batch path in
      match x with
      | Some (`Tree x) -> Lwt.return_ok (Some (t, x, []))
      | _ ->
          let+ tree = request t (module Commands.Tree.Find_tree) (tree, path) in
          Result.map (Option.map (fun tree -> (t, tree, []))) tree

    let remove (t, tree, batch) path =
      let batch = Batch.remove batch path in
      wrap ~batch t (request t (module Commands.Tree.Remove) (tree, path))

    let cleanup (t, tree, _) = request t (module Commands.Tree.Cleanup) tree

    let mem (t, tree, batch) path =
      if Batch.mem batch path then Lwt.return_ok true
      else request t (module Commands.Tree.Mem) (tree, path)

    let mem_tree (t, tree, batch) path =
      if Batch.mem_tree batch path then Lwt.return_ok true
      else request t (module Commands.Tree.Mem_tree) (tree, path)

    let list (t, tree, batch) path =
      let* tree = build t ~tree batch in
      map_tree tree (fun tree ->
          request t (module Commands.Tree.List) (tree, path))

    let merge ~old:(_, old, old') (t, a, a') (_, b, b') =
      let* _, old, _ = build t ~tree:old old' >|= Error.unwrap "build:old" in
      let* _, a, _ = build t ~tree:a a' >|= Error.unwrap "build:a" in
      let* _, b, _ = build t ~tree:b b' >|= Error.unwrap "build:b" in
      wrap t (request t (module Commands.Tree.Merge) (old, a, b))

    module Local = Private.Tree.Local

    let to_local (t, tree, batch) =
      let* tree = build t ~tree batch in
      match tree with
      | Error e -> Lwt.return_error e
      | Ok (_, tree, _) -> (
          let+ res = request t (module Commands.Tree.To_local) tree in
          match res with
          | Ok x ->
              let x = Private.Tree.Local.of_concrete x in
              Ok (x : Private.Store.tree)
          | Error e -> Error e)

    let of_local t x =
      let+ x = Private.Tree.Local.to_concrete x in
      (t, Private.Tree.Local x, [])

    let save (t, tree, batch) =
      let* tree = build t ~tree batch in
      match tree with
      | Error e -> Lwt.return_error e
      | Ok (_, tree, _) -> request t (module Commands.Tree.Save) tree

    let hash (t, tree, batch) =
      let* tree = build t ~tree batch in
      match tree with
      | Error e -> Lwt.return_error e
      | Ok (_, tree, _) -> request t (module Commands.Tree.Hash) tree

    let cleanup_all t = request t (module Commands.Tree.Cleanup_all) ()

    type t = tree
  end

  module Store = struct
    let find t path = request t (module Commands.Store.Find) path

    let set t ~info path value =
      request t (module Commands.Store.Set) (path, info (), value)

    let test_and_set t ~info path ~test ~set =
      request t (module Commands.Store.Test_and_set) (path, info (), (test, set))

    let remove t ~info path =
      request t (module Commands.Store.Remove) (path, info ())

    let find_tree t path =
      let+ tree = request t (module Commands.Store.Find_tree) path in
      Result.map (fun x -> Option.map (fun x -> (t, x, [])) x) tree

    let set_tree t ~info path (_, tree, batch) =
      let* tree = Tree.build t ~tree batch in
      match tree with
      | Error e -> Lwt.return_error e
      | Ok (_, tree, _) ->
          let+ tree =
            request t (module Commands.Store.Set_tree) (path, info (), tree)
          in
          Result.map (fun tree -> (t, tree, [])) tree

    let test_and_set_tree t ~info path ~test ~set =
      let test = Option.map (fun (_, x, _) -> x) test in
      let set = Option.map (fun (_, x, _) -> x) set in
      let+ tree =
        request t
          (module Commands.Store.Test_and_set_tree)
          (path, info (), (test, set))
      in
      Result.map (Option.map (fun tree -> (t, tree, []))) tree

    let mem t path = request t (module Commands.Store.Mem) path
    let mem_tree t path = request t (module Commands.Store.Mem_tree) path

    let merge t ~info branch =
      request t (module Commands.Store.Merge) (info (), branch)

    let merge_commit t ~info commit =
      request t (module Commands.Store.Merge_commit) (info (), commit)

    let last_modified t path =
      request t (module Commands.Store.Last_modified) path
  end

  module Commit = struct
    include C.Commit

    let v t ~info ~parents ((_, tree, batch) : Tree.t) : t Error.result Lwt.t =
      let* tree = Tree.build t ~tree batch in
      match tree with
      | Error e -> Lwt.return_error e
      | Ok (_, tree, _) -> (
          request t (module Commands.Commit_v) (info (), parents, tree)
          >|= function
          | Error e -> Error e
          | Ok (x : t) ->
              let key = Commit.key x in
              Cache.Commit.add Cache.commit key x;
              Ok x)

    let of_key t key =
      if Cache.(Commit.mem commit key) then
        Lwt.return_ok (Some Cache.(Commit.find commit key))
      else
        let* commit = request t (module Commands.Commit_of_key) key in
        match commit with
        | Ok c ->
            Option.iter (Cache.Commit.add Cache.commit key) c;
            Lwt.return_ok c
        | Error e -> Lwt.return_error e

    let of_hash t hash = request t (module Commands.Commit_of_hash) hash

    let hash t commit =
      request t (module Commands.Commit_hash_of_key) (key commit)

    let tree t commit = (t, tree commit, [])
  end
end
