open Lwt.Syntax
open Irmin_server_internal

let main ~readonly ~root ~uri ~tls ~store ~contents ~hash ~config_path
    (module Codec : Conn.Codec.S) =
  let store, config =
    Irmin_unix.Resolver.load_config ?root ?config_path ?store ?hash ?contents ()
  in
  let config =
    match uri with Some uri -> Irmin_http.config uri config | None -> config
  in
  let (module Store : Irmin.Generic_key.S) =
    Irmin_unix.Resolver.Store.generic_keyed store
  in
  let module Server = Irmin_server.Make_ext (Codec) (Store) in
  let tls_config =
    match tls with Some (c, k) -> Some (`Cert_file c, `Key_file k) | _ -> None
  in
  let uri =
    Irmin.Backend.Conf.(get config Irmin_http.Conf.Key.uri)
    |> Option.value ~default:Cli.default_uri
  in
  let config = if readonly then Server.readonly config else config in
  let* server = Server.v ?tls_config ~uri config in
  let root = match root with Some root -> root | None -> "" in
  Logs.app (fun l -> l "Listening on %a, store: %s" Uri.pp_hum uri root);
  Server.serve server

let main readonly root uri tls (store, hash, contents) codec config_path () =
  Lwt_main.run
  @@ main ~readonly ~root ~uri ~tls ~store ~contents ~hash ~config_path codec

open Cmdliner

let root =
  let doc = Arg.info ~doc:"Irmin store path" [ "r"; "root" ] in
  Arg.(value @@ opt (some string) None doc)

let readonly =
  let doc =
    Arg.info
      ~doc:
        "Open in read-only mode. This only has an effect when using irmin-pack"
      [ "readonly" ]
  in
  Arg.(value @@ flag doc)

let tls =
  let doc = Arg.info ~docv:"CERT_FILE,KEY_FILE" ~doc:"TLS config" [ "tls" ] in
  Arg.(value @@ opt (some (pair string string)) None doc)

let main_term =
  Term.(
    const main $ readonly $ root $ Cli.uri $ tls
    $ Irmin_unix.Resolver.Store.term ()
    $ Cli.codec $ Cli.config_path $ Cli.setup_log)

let () =
  let info = Term.info "irmin-server" in
  Term.exit @@ Term.eval (main_term, info)
