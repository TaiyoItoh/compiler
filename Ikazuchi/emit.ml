open Asm

external getf : float -> int32 = "getf"

let stackset = ref S.empty (* すでにSaveされた変数の集合 (caml2html: emit_stackset) *)
let stackmap = ref [] (* Saveされた変数の、スタックにおける位置 (caml2html: emit_stackmap) *)
let save x =
  stackset := S.add x !stackset;
  if not (List.mem x !stackmap) then
    stackmap := !stackmap @ [x]
let savef x =
  stackset := S.add x !stackset;
  if not (List.mem x !stackmap) then
	stackmap := !stackmap @ [x]
 (*   (let pad =
      if List.length !stackmap mod 2 = 0 then [] else [Id.gentmp Type.Int] in
    stackmap := !stackmap @ pad @ [x; x]) *)
let locate x =
  let rec loc = function
    | [] -> []
    | y :: zs when x = y -> 0 :: List.map succ (loc zs)
    | y :: zs -> List.map succ (loc zs) in
  loc !stackmap
let offset x = (* Format.eprintf "%s %d@." x (- List.hd (locate x)); *) - List.hd (locate x)
let stacksize () = align (List.length !stackmap + 1)

let reg r =
  if is_reg r
  then String.sub r 1 (String.length r - 1)
  else r

let dummy_counter = ref 0

(* 関数呼び出しのために引数を並べ替える(register shuffling) (caml2html: emit_shuffle) *)
let rec shuffle sw xys =
  (* remove identical moves *)
  let _, xys = List.partition (fun (x, y) -> x = y) xys in
  (* find acyclic moves *)
  match List.partition (fun (_, y) -> List.mem_assoc y xys) xys with
  | [], [] -> []
  | (x, y) :: xys, [] -> (* no acyclic moves; resolve a cyclic move *)
      (y, sw) :: (x, y) :: shuffle sw (List.map
					 (function
					   | (y', z) when y = y' -> (sw, z)
					   | yz -> yz)
					 xys)
  | xys, acyc -> acyc @ shuffle sw xys

type dest = Tail | NonTail of Id.t (* 末尾かどうかを表すデータ型 (caml2html: emit_dest) *)
let rec g oc = function (* 命令列のアセンブリ生成 (caml2html: emit_g) *)
  | dest, Ans(exp) -> g' oc (dest, exp)
  | dest, Let((x, t), exp, e) ->
      g' oc (NonTail(x), exp);
      g oc (dest, e)
and g' oc = function (* 各命令のアセンブリ生成 (caml2html: emit_gprime) *)
  (* 末尾でなかったら計算結果をdestにセット (caml2html: emit_nontail) *)
  | NonTail(_), Nop -> Printf.fprintf oc ""
  | NonTail(x), Set(i) ->
	 Printf.fprintf oc "\tli\t%s, %d\n" x i;
  | NonTail(x), SetL(Id.L(y)) -> Printf.fprintf oc "\tllw\t%s, (%s)\n" x y (* llw *)
  | NonTail(x), SetA(Id.L(y)) ->
	 Printf.fprintf oc "\tla\t%s, %s\n" x y
  | NonTail(x), Mov(y) ->
      if x <> y then Printf.fprintf oc "\tmove\t%s, %s\n" x y
  | NonTail(x), Neg(y) ->
      Printf.fprintf oc "\tsub\t%s, %s, %s\n" x reg_zero y
  | NonTail(x), Add(y, z') ->
      (match z' with
      | V(z) -> Printf.fprintf oc "\tadd\t%s, %s, %s\n" x y z
      | C(i) -> Printf.fprintf oc "\taddi\t%s, %s, %d\n" x y i)
  | NonTail(x), Sub(y, z') ->
      (match z' with
      | V(z) -> Printf.fprintf oc "\tsub\t%s, %s, %s\n" x y z
      | C(i) -> Printf.fprintf oc "\tsubi\t%s, %s, %d\n" x y i)
  | NonTail(x), Mul(y, z') ->
       Printf.fprintf oc "\tsll\t%s, %s, 2\n" x y (* z' = C(4) *)
  | NonTail(x), Div(y, z') ->
       Printf.fprintf oc "\tsrl\t%s, %s, 1\n" x y (* z' = C(2) *)
  | NonTail(x), Ld(y, V(z)) ->
      (Printf.fprintf oc "\tadd\t%s, %s, %s\n" reg_tmp y z;
       Printf.fprintf oc "\tlw\t%s, 0(%s)\n" x reg_tmp)
  | NonTail(x), Ld(y, C(j)) ->
       Printf.fprintf oc "\tlw\t%s, %d(%s)\n" x j y
  | NonTail(_), St(x, y, V(z)) ->
      (Printf.fprintf oc "\tadd\t%s, %s, %s\n" reg_tmp y z;
       Printf.fprintf oc "\tsw\t%s, 0(%s)\n" x reg_tmp)
  | NonTail(_), St(x, y, C(j)) ->
       Printf.fprintf oc "\tsw\t%s, %d(%s)\n" x j y
  | NonTail(x), FMovD(y) ->
      if x <> y then Printf.fprintf oc "\tmove\t%s, %s\n" x y
  | NonTail(x), FNegD(y) ->
      Printf.fprintf oc "\tfneg\t%s, %s\n" x y
  | NonTail(x), FAddD(y, z) ->
      Printf.fprintf oc "\tfadd\t%s, %s, %s\n" x y z
  | NonTail(x), FSubD(y, z) ->
      (Printf.fprintf oc "\tfneg\t%s, %s\n" reg_tmp z;
      Printf.fprintf oc "\tfadd\t%s, %s, %s\n" x y reg_tmp)
  | NonTail(x), FMulD(y, z) ->
      Printf.fprintf oc "\tfmul\t%s, %s, %s\n" x y z
  | NonTail(x), FDivD(y, z) ->
	 (Printf.fprintf oc "\tfinv\t%s, %s\n" reg_tmp z;
      Printf.fprintf oc "\tfmul\t%s, %s, %s\n" x y reg_tmp)
  (* lw?sw? *)
  | NonTail(x), LdDF(y, V(z)) ->
      (Printf.fprintf oc "\tadd\t%s, %s, %s\n" reg_tmp y z;
       Printf.fprintf oc "\tlw\t%s, 0(%s)\n" x reg_tmp)
  | NonTail(x), LdDF(y, C(j)) ->
       Printf.fprintf oc "\tlw\t%s, %d(%s)\n" x j y
  | NonTail(_), StDF(x, y, V(z)) ->
      (Printf.fprintf oc "\tadd\t%s, %s, %s\n" reg_tmp y z;
       Printf.fprintf oc "\tsw\t%s, 0(%s)\n" x reg_tmp)
  | NonTail(_), StDF(x, y, C(j)) ->
       Printf.fprintf oc "\tsw\t%s, %d(%s)\n" x j y
  | NonTail(_), Comment(s) -> Printf.fprintf oc "\t# %s\n" s
  (* 退避の仮想命令の実装 (caml2html: emit_save) lw?sw? *)
  | NonTail(_), Save(x, y) when List.mem x allregs && not (S.mem y !stackset) ->
      save y;
      Printf.fprintf oc "\tsw\t%s, %d(%s)\n" x (offset y) reg_sp
  (* | NonTail(_), Save(x, y) when List.mem x allfregs && not (S.mem y !stackset) ->
      savef y;
      Printf.fprintf oc "\tsw\t%s, %d(%s)\n" x (offset y) reg_sp *)
  | NonTail(_), Save(x, y) -> Printf.fprintf oc "" (* assert (S.mem y !stackset) *) ;
  (* 復帰の仮想命令の実装 (caml2html: emit_restore) *)
  | NonTail(x), Restore(y) when List.mem x allregs ->
      Printf.fprintf oc "\tlw\t%s, %d(%s)\n" x (offset y) reg_sp
  | NonTail(x), Restore(y) ->
      (* assert (List.mem x allfregs); *)
      Printf.fprintf oc "\tlw\t%s, %d(%s)\n" x (offset y) reg_sp
  (* 末尾だったら計算結果を第一レジスタにセットしてret (caml2html: emit_tailret) *)
  | Tail, (Nop | St _ | StDF _ | Comment _ | Save _ as exp) ->
      g' oc (NonTail(Id.gentmp Type.Unit), exp);
      Printf.fprintf oc "\tjr\t%s\n" reg_ra;
  | Tail, (Set _ | SetL _ | SetA _ | Mov _ | Neg _ | Add _ | Sub _ |  Mul _ | Div _ | Ld _ as exp) ->
      g' oc (NonTail(reg_rv), exp);
      Printf.fprintf oc "\tjr\t%s\n" reg_ra;
  | Tail, (FMovD _ | FNegD _ | FAddD _ | FSubD _ | FMulD _ | FDivD _ | LdDF _  as exp) ->
      g' oc (NonTail(reg_rv), exp);
      Printf.fprintf oc "\tjr\t%s\n" reg_ra;
  | Tail, (Restore(x) as exp) ->
      (match locate x with
      | [i] -> g' oc (NonTail(reg_rv), exp)
      | [i; j] when i + 1 = j -> g' oc (NonTail(reg_rv), exp)
      | _ -> assert false);
      Printf.fprintf oc "\tjr\t%s\n" reg_ra;
  | Tail, IfEq(x, V(y), e1, e2) ->
      g'_tail_if oc e1 e2 "beq"
      (Printf.sprintf "bne\t%s, %s, " x y)
  | Tail, IfEq(x, C(i), e1, e2) ->
      Printf.fprintf oc "\tli\t%s, %d\n" reg_tmp i;
      g'_tail_if oc e1 e2 "beq"
      (Printf.sprintf "bne\t%s, %s, " x reg_tmp)
  | Tail, IfLE(x, y', e1, e2) ->
      (match y' with
      | V(y) -> Printf.fprintf oc "\tslt\t%s, %s, %s\n" reg_tmp y x
      | C(i) -> Printf.fprintf oc "\tli\t%s, %d\n" reg_tmp i;
				Printf.fprintf oc "\tslt\t%s, %s, %s\n" reg_tmp reg_tmp x);
      g'_tail_if oc e1 e2 "ble"
      (Printf.sprintf "bne\t%s, %s, " reg_tmp reg_zero)
  | Tail, IfGE(x, y', e1, e2) ->
      (match y' with
      | V(y) -> Printf.fprintf oc "\tslt\t%s, %s, %s\n" reg_tmp x y
      | C(i) -> Printf.fprintf oc "\tli\t%s, %d\n" reg_tmp i;
				Printf.fprintf oc "\tslt\t%s, %s, %s\n" reg_tmp x reg_tmp);
      g'_tail_if oc e1 e2 "bge"
      (Printf.sprintf "bne\t%s, %s, " reg_tmp reg_zero)
  | Tail, IfFEq(x, y, e1, e2) ->
	 Printf.fprintf oc "\tfslt\t%s, %s, %s\n" reg_tmp x y;
	 Printf.fprintf oc "\tfslt\t%s, %s, %s\n" reg_sw y x;
      g'_tail_if oc e1 e2 "bfeq"
      (Printf.sprintf "bne\t%s, %s, " reg_tmp reg_sw)
  | Tail, IfFLE(x, y, e1, e2) ->
	  Printf.fprintf oc "\tfslt\t%s, %s, %s\n" reg_tmp y x;
      g'_tail_if oc e1 e2 "bfle"
      (Printf.sprintf "bne\t%s, %s, " reg_tmp reg_zero)
  | NonTail(z), IfEq(x, V(y), e1, e2) ->
      g'_non_tail_if oc (NonTail(z)) e1 e2 "beq"
      (Printf.sprintf "bne\t%s, %s, " x y)
  | NonTail(z), IfEq(x, C(i), e1, e2) ->
      Printf.fprintf oc "\tli\t%s, %d\n" reg_tmp i;
      g'_non_tail_if oc (NonTail(z)) e1 e2 "beq"
      (Printf.sprintf "bne\t%s, %s, " x reg_tmp)
  | NonTail(z), IfLE(x, y', e1, e2) ->
      (match y' with
      | V(y) -> Printf.fprintf oc "\tslt\t%s, %s, %s\n" reg_tmp y x
      | C(i) -> Printf.fprintf oc "\tli\t%s, %d\n" reg_tmp i;
				Printf.fprintf oc "\tslt\t%s, %s, %s\n" reg_tmp reg_tmp x);
      g'_non_tail_if oc (NonTail(z)) e1 e2 "ble"
      (Printf.sprintf "bne\t%s, %s, " reg_tmp reg_zero)
  | NonTail(z), IfGE(x, y', e1, e2) ->
      (match y' with
      | V(y) -> Printf.fprintf oc "\tslt\t%s, %s, %s\n" reg_tmp x y
      | C(i) -> Printf.fprintf oc "\tli\t%s, %d\n" reg_tmp i;
				Printf.fprintf oc "\tslt\t%s, %s, %s\n" reg_tmp x reg_tmp);
	  g'_non_tail_if oc (NonTail(z)) e1 e2 "bge"
      (Printf.sprintf "bne\t%s, %s, " reg_tmp reg_zero)
  | NonTail(z), IfFEq(x, y, e1, e2) ->
	 Printf.fprintf oc "\tfslt\t%s, %s, %s\n" reg_tmp x y;
	 Printf.fprintf oc "\tfslt\t%s, %s, %s\n" reg_sw y x;
      g'_non_tail_if oc (NonTail(z)) e1 e2 "bfeq"
      (Printf.sprintf "bne\t%s, %s, " reg_tmp reg_sw)
  | NonTail(z), IfFLE(x, y, e1, e2) ->
	  Printf.fprintf oc "\tfslt\t%s, %s, %s\n" reg_tmp y x;
      g'_non_tail_if oc (NonTail(z)) e1 e2 "bfle"
      (Printf.sprintf "bne\t%s, %s, " reg_tmp reg_zero)
  (* 関数呼び出しの仮想命令の実装 (caml2html: emit_call) *)
  | Tail, CallCls(x, ys, zs) -> (* 末尾呼び出し (caml2html: emit_tailcall) *)
      g'_args oc [(x, reg_cl)] ys zs;
      Printf.fprintf oc "\tlw\t%s, 0(%s)\n" reg_tmp reg_cl;
      Printf.fprintf oc "\tjr\t%s\n" reg_tmp;
  | Tail, CallDir(Id.L(x), ys, zs) -> (* 末尾呼び出し *)
      g'_args oc [] ys zs;
      Printf.fprintf oc "\tj\t%s\n" x;
  | NonTail(a), CallCls(x, ys, zs) ->
      g'_args oc [(x, reg_cl)] ys zs;
      let ss = stacksize () in
      Printf.fprintf oc "\tsw\t%s, %d(%s)\n" reg_ra (- (ss - 1)) reg_sp;
      Printf.fprintf oc "\tlw\t%s, 0(%s)\n" reg_tmp reg_cl;
      Printf.fprintf oc "\tsubi\t%s, %s, %d\n" reg_sp reg_sp ss;
	  incr dummy_counter;
      Printf.fprintf oc "\tla\t%s, dummy_label.%d\n" reg_ra !dummy_counter;
      Printf.fprintf oc "\tjr\t%s\n" reg_tmp;
      Printf.fprintf oc "dummy_label.%d:\n" !dummy_counter;
      Printf.fprintf oc "\taddi\t%s, %s, %d\n" reg_sp reg_sp ss;
      Printf.fprintf oc "\tlw\t%s, %d(%s)\n" reg_ra (- (ss - 1)) reg_sp;
      if List.mem a allregs && a <> reg_rv then
        Printf.fprintf oc "\tmove\t%s, %s\n" a reg_rv
     (* else if List.mem a allfregs && a <> fregs.(0) then
        Printf.fprintf oc "\tmove\t%s, %s, %s\n" a fregs.(0) reg_zero *)
  | NonTail(a), CallDir(Id.L(x), ys, zs) ->
      g'_args oc [] ys zs;
      let ss = stacksize () in
      Printf.fprintf oc "\tsw\t%s, %d(%s)\n" reg_ra (- (ss - 1)) reg_sp;
      Printf.fprintf oc "\tsubi\t%s, %s, %d\n" reg_sp reg_sp ss;
      Printf.fprintf oc "\tjal\t%s\n" x;
      Printf.fprintf oc "\taddi\t%s, %s, %d\n" reg_sp reg_sp ss;
      Printf.fprintf oc "\tlw\t%s, %d(%s)\n" reg_ra (- (ss - 1)) reg_sp;
      if List.mem a allregs && a <> reg_rv then
        Printf.fprintf oc "\tmove\t%s, %s\n" a reg_rv
     (* else if List.mem a allfregs && a <> fregs.(0) then
        Printf.fprintf oc "\tmove\t%s, %s, %s\n" a fregs.(0) reg_zero *)
(*  | NonTail(_), _ -> Printf.fprintf oc "\tERORR_NONTAIL\n"
  | Tail(_), _ -> Printf.fprintf oc "\tERORR_TAIL\n" *)
and g'_tail_if oc e1 e2 b bn =
  let b_else = Id.genid (b ^ "_else") in
  Printf.fprintf oc "\t%s%s\n" bn b_else;
  Printf.fprintf oc "\tnop\n";
  let stackset_back = !stackset in
  g oc (Tail, e1);
  Printf.fprintf oc "%s:\n" b_else;
  stackset := stackset_back;
  g oc (Tail, e2)
and g'_non_tail_if oc dest e1 e2 b bn =
  let b_else = Id.genid (b ^ "_else") in
  let b_cont = Id.genid (b ^ "_cont") in
  Printf.fprintf oc "\t%s%s\n" bn b_else;
  Printf.fprintf oc "\tnop\n";
  let stackset_back = !stackset in
  g oc (dest, e1);
  let stackset1 = !stackset in
  Printf.fprintf oc "\tj\t%s\n" b_cont;
  Printf.fprintf oc "%s:\n" b_else;
  stackset := stackset_back;
  g oc (dest, e2);
  Printf.fprintf oc "%s:\n" b_cont;
  let stackset2 = !stackset in
  stackset := S.inter stackset1 stackset2
and g'_args oc x_reg_cl ys zs =
  let (i, yrs) =
    List.fold_left
      (fun (i, yrs) ys -> (i + 1, (ys, regs.(i)) :: yrs))
      (0, x_reg_cl)
      (ys @ zs) in
  List.iter
    (fun (y, r) -> Printf.fprintf oc "\tmove\t%s, %s\n" r y)
    (shuffle reg_sw yrs) (*;
  let (d, zfrs) =
    List.fold_left
      (fun (d, zfrs) zs -> (d + 1, (zs, regs.(d)) :: zfrs))
      (List.length ys, [])
      zs in
  List.iter
    (fun (z, fr) -> Printf.fprintf oc "\tmove\t%s, %s\n" fr z)
    (shuffle reg_sw zfrs) *)

let h oc { name = Id.L(x); args = _; fargs = _; body = e; ret = _ } =
  Printf.fprintf oc "%s:\n" x;
  stackset := S.empty;
  stackmap := [];
  g oc (Tail, e)

let f oc (Prog(data, fundefs, e)) =
  Format.eprintf "generating assembly...@.";
  Printf.fprintf oc ".data\n";
  List.iter
  (fun (Id.L(x), d) ->
    Printf.fprintf oc "%s:\t# %f\n" x d;
	(* ld?lx? *)
    Printf.fprintf oc "\t.long\t0x%lx\n" (getf d))
  data;
  Printf.fprintf oc ".text\n";
  Printf.fprintf oc "\t.globl main\n";
  List.iter (fun fundef -> h oc fundef) fundefs;
  Printf.fprintf oc "main: # main entry point\n";
  Printf.fprintf oc "\t# main program start\n";
  stackset := S.empty;
  stackmap := [];
  g oc (NonTail(reg_rv), e);
  Printf.fprintf oc "\t# main program end\n";
  Printf.fprintf oc "\tjr\t%s\n" reg_ra;
