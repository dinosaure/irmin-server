open Lwt.Infix

module Rpc = struct
  module Codec = Irmin_server_internal.Conn.Codec.Bin
  module Store = Irmin_mem.KV.Make (Irmin.Contents.String)
  module Client = Irmin_client_unix.Make_ext (Codec) (Store)
  module Server = Irmin_server.Make_ext (Codec) (Store)
end

let test name f client _switch () =
  Logs.debug (fun l -> l "Running: %s" name);
  f client

let run_server () =
  let path = Unix.getcwd () in
  let uri = Uri.of_string ("unix://" ^ Filename.concat path "test.socket") in
  let stop, wake = Lwt.wait () in
  Lwt.async (fun () ->
      let conf = Irmin_mem.config () in
      Rpc.Server.v ~uri conf >>= Rpc.Server.serve ~stop);
  (wake, uri)

let suite client all =
  List.map
    (fun (name, speed, f) ->
      Alcotest_lwt.test_case name speed (test name f client))
    all
