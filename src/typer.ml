(* {{{ COPYING *(

  This file is part of Merlin, an helper for ocaml editors

  Copyright (C) 2013  Frédéric Bour  <frederic.bour(_)lakaban.net>
                      Thomas Refis  <refis.thomas(_)gmail.com>
                      Simon Castellan  <simon.castellan(_)iuwt.fr>

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the "Software"),
  to deal in the Software without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
  sell copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall
  the authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising
  from, out of or in connection with the software or the use or other dealings
  in the Software.

)* }}} *)

open Misc

module Context = struct
  type state = exn list * Env.t * Typedtree.structure Location.loc list

  type sig_item = Types.signature Location.loc list or_exn
  type str_item = Typedtree.structure Location.loc list or_exn
  type sig_in_sig_modtype = unit
  type sig_in_sig_module  = unit
  type sig_in_str_modtype = unit
  type str_in_module      = unit
end

let initial_env =
  let env = lazy begin
    Ident.reinit();
    try
      if !Clflags.nopervasives
      then Env.initial
      else Env.open_pers_signature "Pervasives" Env.initial
    with Not_found ->
      failwith "cannot open pervasives.cmi"
  end in
  fun () -> let lazy env = env in
            Extensions_utils.register env

let protect_typer f =
  let errors, result = 
    Misc.catch_join (Merlin_parsing.catch_warnings (fun () -> Merlin_types.catch_errors f))
  in
  errors,
  Misc.sum raise (fun x -> x) result

module Fold = struct
  (* Initial state *)
  let sig_root _ = [], initial_env (), []
  let str_root _ = [], initial_env (), []

  (* Fold items *)
  let sig_item _ = failwith "TODO"

  let str_item step (exns,env,trees' as state) =
    match Chunk.Spine.value step with
    | Inl exn -> state, Inl exn
    | Inr items ->
      let exns', (env, exns, trees) =
        protect_typer
        begin fun () ->
          List.fold_left
          begin fun (env,exns,ts) d ->
          try
            let t,_,env = 
              Typemod.type_structure env [d.Location.txt] d.Location.loc
            in
            (env, exns, {d with Location.txt = t} :: ts)
          with exn -> (env, exn :: exns, ts)
          end (env, exns, []) items
        end
      in
      (exns' @ exns, env, trees @ trees'), Inr (List.rev trees)

  (* Fold structure shape *)
  let str_in_module step (exns,env,trees as state) =
    match Chunk.Spine.value step with
    | Inl exn -> state, ()
    | Inr (_, {Location. txt = pmod; _}) ->
    match
      protect_typer
      begin fun () -> try
        let open Typedtree in
        let open Parsetree in
        let rec filter_constraint md =
          let update f = function
            | None -> None
            | Some md' -> Some (f md')
          in
          match md.pmod_desc with
            | Pmod_structure _ -> Some md
            | Pmod_functor (a,b,md) ->
                update
                  (fun md' -> {md with pmod_desc = Pmod_functor (a,b,md')})
                  (filter_constraint md)
            | Pmod_constraint (md,_) ->
                update (fun x -> x) (filter_constraint md)
            | _ -> None
        in
        let pmod = match filter_constraint pmod with
          | Some pmod' -> pmod'
          | None -> pmod
        in
        let rec find_structure md =
          match md.mod_desc with
            | Tmod_structure _ -> Some md
            | Tmod_functor (_,_,_,md) -> find_structure md
            | Tmod_constraint (md,_,_,_) -> Some md
            | _ -> None
        in
        let tymod = Typemod.type_module env pmod in
        match find_structure tymod with
          | None -> None
          | Some md -> Some (exns, md.mod_env)
      with exn -> Some (exn :: exns, env)
      end
    with
    | exns', None -> 
      (exns' @ exns, env, trees), ()
    | exns', Some (exns, env) -> 
      (exns' @ exns, env, trees), ()

  (* Fold signature shape *)
  let sig_in_sig_modtype _ = failwith "TODO"
  let sig_in_sig_module  _ = failwith "TODO"
  let sig_in_str_modtype _ = failwith "TODO"
end

module Spine = Spine.Transform (Context) (Chunk.Spine) (Fold)
type t = Spine.t
let update = Spine.update

let exns  t = fst3 (Spine.get_state t)
let env   t = snd3 (Spine.get_state t)
let trees t = thd3 (Spine.get_state t)
