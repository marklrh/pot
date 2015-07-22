(* Take basic parser combinator and do optimization *)

open Print_code
open Format
open Gengenlet

open Sparser

module PP = struct
  let pp_code code = print_code Format.std_formatter code
  let pp_closed_code code = print_closed_code Format.std_formatter code
  let format_code closed_code = format_code Format.std_formatter closed_code
end

(* state is dynamic, grammar is static *)

module CFParser = struct

  open BasicFParser

  let gen_lit_parser : char -> char parser_code =
    fun c state -> .<
      let ix = (.~state).index in
      let f = Failure .~state in
      if ix < (.~state).length then
        let e1 = (.~state).input.[ix] in
        if e1 = c then .~(
          if c = '\n' then
            .<Success (e1, {.~state with row = (.~state).row + 1; col = 0; index = ix + 1})>.
          else
            .<Success (e1, {.~state with col = (.~state).col + 1; index = ix + 1})>.)
        else f
      else f
    >.

  let gen_seq_parser :
    ('a parser_code) -> ('b parser_code) -> ('a * 'b) parser_code =
    fun pcx pcy state -> .<
      let res1 = .~(pcx state) in
        match res1 with
        | Success (r1, state1) -> begin
          let res2 = .~(pcy .<state1>.) in
          match res2 with
          | Success (r2, state2) -> Success ((r1, r2), state2)
          | Failure _ -> Failure state1 end
        | Failure _ -> Failure (.~state) >.

  let gen_left_parser :
    ('a parser_code) -> ('b parser_code) -> ('a parser_code) =
    fun pcx pcy state -> .<
      let res1 = .~(pcx state) in
      match res1 with
      | Success (r1, state1) -> begin
        let res2 = .~(pcy .<state1>.) in
        match res2 with
        | Success (_, state2) -> Success (r1, state2)
        | Failure _ -> Failure (.~state) end
      | Failure _ -> Failure (.~state) >.

  let gen_right_parser :
    ('a parser_code) -> ('b parser_code) -> ('b parser_code) =
    fun pcx pcy state -> .<
      let res1 = .~(pcx state) in
      match res1 with
      | Success (_, state1) -> begin
        let res2 = .~(pcy .<state1>.) in
        match res2 with
        | Success (_, _) as s -> s
        | Failure _ -> Failure (.~state) end
      | Failure _ -> Failure (.~state) >.

  let gen_either_parser :
    ('a parser_code) list -> ('a parser_code) =
    fun l s ->
      let combine : ('a parser_code) -> ('a parser_code) -> ('a parser_code) =
        fun pcx pcy state -> .<
          let res1 = .~(pcx state) in
          match res1 with
          | Success (_, _) as s -> s
          | Failure _ -> .~(pcy state)>. in
      match l with
      | x :: res ->
        (List.fold_left combine x res) s
      | _ -> failwith "Invalid grammar"

  let gen_rep_parser : ('a parser_code) -> ('a list parser_code) = fun p s ->
    .<let rec rep_parser state acc =
        let res = .~(p .<state>.) in
        match res with
        | Success (r1, s1) -> rep_parser s1 (r1 :: acc)
        | Failure s1 -> Success (List.rev acc, s1) in rep_parser .~s []>.

  let gen_repsep_parser : ('a parser_code) -> ('b parser_code) -> ('a list parser_code) =
    fun ap bp s ->
      .<let rec repsep_parser state acc =
          let res = .~(ap .<state>.) in
          match res with
          | Success (r1, s1) -> begin
            let res2 = .~(bp .<s1>.) in
            match res2 with
            | Success (_, s2) -> repsep_parser s2 (r1 :: acc)
            | Failure s3 -> Success (List.rev (r1 :: acc), s1) end
          | Failure s1 -> Success (List.rev acc, s1)
        in repsep_parser .~s []>.

  let gen_trans_parser : ('a -> 'b) -> ('a parser_code) -> ('b parser_code) =
    fun trans ap state -> .<
      let res = .~(ap state) in
      match res with
      | Success (r, s) -> Success ((trans r), s)
      | Failure _ as f -> f>.

  let gen_tw_parser : (char code -> bool code) -> string parser_code = fun pred s -> .<
    let buf = Buffer.create 10 in
    let len = (.~s).length in
    let rec tw_parser s =
      let i = s.index in
      if i < len then
        let c = s.input.[i] in
        if .~(pred .<c>.) then begin
          Buffer.add_char buf c;
          if c = '\n' then
            tw_parser {s with row = s.row + 1; col = 0; index = i + 1}
          else
            tw_parser {s with col = s.col + 1; index = i + 1} end
        else Buffer.contents buf, s
      else Buffer.contents buf, s in
    let str, state = tw_parser .~s in
    Success (str, state)>.

  (*
  let analyze_grammar : type a. a cgrammar -> (string, bool) Hashtbl.t = fun g ->
    let htb : (string, bool) Hashtbl.t = Hashtbl.create 10 in
    let rec dfs : type a. a cgrammar -> unit = fun g ->
      match g with
      | Lit _ -> ()
      | NT (id, g) ->
        if Hashtbl.mem htb id then () else begin
          Hashtbl.add htb id true;
          dfs (Lazy.force g) end
      | Either gl -> List.iter dfs gl
      | Seq (g1, g2) -> dfs g1; dfs g2
      | Left (g1, g2) -> dfs g1; dfs g2
      | Right (g1, g2) -> dfs g1; dfs g2
      | Rep g -> dfs g
      | Repsep (g1, g2) -> dfs g1; dfs g2
      | Trans (_, g) -> dfs g
      | _ -> () in
    dfs g;
    htb *)

  let preprocess_grammar : type a. a cgrammar -> CodeMap.t = fun g ->
    let rec dfs : type a. CodeMap.t -> a cgrammar -> CodeMap.t =
      fun m g ->
        match g with
        | Lit _ -> m
        | Seq (g1, g2) ->
          let m' = dfs m g1 in dfs m' g2
        | Left (g1, g2) ->
          let m'  = dfs m  g1 in dfs m' g2
        | Right (g1, g2) ->
          let m' = dfs m g1 in dfs m' g2
        | Either gl ->
          let ff g m = dfs m g in
          List.fold_right ff gl m
        | Rep g -> dfs m g
        | Repsep (g1, g2) ->
          let m' = dfs m g1 in dfs m' g2
        | TakeWhile _ -> m
        | Trans (_, g1) -> dfs m g1
        | FNT lp -> begin
          let k, g = Lazy.force lp in
          match CodeMap.find m k with
          | Some _ -> m
          | None ->
            let m' = CodeMap.add m k (ref (fun _ -> assert false)) in
            dfs m' g end
        | _ -> failwith "Invalid type constructor" in
    dfs CodeMap.empty g

  let gen_parser : type a. a parser_generator = fun c state ->
    let m = ref CodeMap.empty in
    let rec gen_parser : type a. a parser_generator = fun c state ->
      match c with
      | Lit e -> gen_lit_parser e state
      | Either gl -> gen_either_parser (List.map gen_parser gl) state
      | Seq (g1, g2) ->
        let c1 = gen_parser g1 and c2 = gen_parser g2 in
        gen_seq_parser c1 c2 state
      | Left (g1, g2) ->
        let c1 = gen_parser g1 and c2 = gen_parser g2 in
        gen_left_parser c1 c2 state
      | Right (g1, g2) ->
        let c1 = gen_parser g1 and c2 = gen_parser g2 in
        gen_right_parser c1 c2 state
      | Rep g -> gen_rep_parser (gen_parser g) state
      | Repsep (g1, g2) ->
        let c1 = gen_parser g1 and c2 = gen_parser g2 in
        gen_repsep_parser c1 c2 state
      | Trans (f, g) ->
        let c1 = gen_parser g in
        gen_trans_parser f c1 state
      | TakeWhile pred -> gen_tw_parser pred state
      | FNT lp -> begin
        let k, g = Lazy.force lp in
        match CodeMap.find !m k with
        | None -> begin
          m := CodeMap.add !m k (ref (fun _ -> assert false));
          let pcode = gen_parser g in
          match CodeMap.find !m k with
          | None -> assert false
          | Some cr -> cr := pcode;
          pcode state end
        | Some cr -> !cr state end
      | _ -> assert false in
    gen_parser c state

end

module Test_expansion = struct
  open BasicFParser

  let test_I () =
    let s = init_state_from_string "cd" in
    let parser_code = CFParser.gen_parser (FTIParser.test2) in
    print_endline "reach here";
    match Runcode.(!. (parser_code .<s>.)) with
    | Success _ -> print_endline "yeah!"
    | Failure _ -> print_endline "no"

    (*
    let map = CFParser.preprocess_grammar FJsonParser.json_parser in
    let iterf : type a. a CodeMap.key -> a parser_code ref -> unit =
      fun _ cr -> PP.pp_code .<fun s -> !cr .<s>.>. in
    CodeMap.iter map {CodeMap.f=iterf};
    Printf.printf "size : %d\n" (CodeMap.size map)
       *)
end

module Test = struct

  open Sparser.BasicFParser

  let state s = init_state_from_string s

  let dump_code (g, ss, _, _) () =
    let parser_code = CFParser.gen_parser g in
    PP.pp_code (.<fun s -> .~(parser_code .<s>.)>.)

  let run_code (g, ss, p1, p2) () =
    let parser_code = CFParser.gen_parser g in
    let f s =
      match Runcode.(!. (parser_code .<s>.)) with
      | Success (res, s) -> p1 res; p2 s
      | Failure s -> Printf.printf "Failure. "; p2 s in
    List.iter f ss

  let pp_char_list cl =
    let buf = Buffer.create 10 in
    List.iter (Buffer.add_char buf) cl;
    Printf.printf "Success: %s\n" (Buffer.to_bytes buf)

  let pp_state s =
    let s = String.sub s.input s.index (s.length - s.index) in
    let s = if String.length s = 0 then "Empty" else "Left: " ^ s in
    Printf.printf "State: %s\n" s

  let repg = Rep (lit 'c'), [
      state "cc";
      state "c";
      state "ccccccc"], pp_char_list, pp_state

  let repsepg = Repsep ((lit 'c'), (lit ',')), [
      state "c,c";
      state "c";
      state "c,c,c,c,c,";
      state "";
      state ","], pp_char_list, pp_state

  let strg = ((lit '"') >> (TakeWhile (fun c -> .<.~c <> '"'>.)) << (lit '"')),
             [state "\"abc\"";state "\"a\"";state "\"\""; state "\""; state "\"a"],
             print_endline, pp_state

  let test_rep = run_code repg

  let test_repsep = run_code repsepg

  let test_str = run_code strg

  let see_str = dump_code strg

end

let () = Runcode.(add_search_path "./_build")

let () =
  Test_expansion.test_I ()
