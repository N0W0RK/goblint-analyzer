(** A node in the Control Flow Graph is either a statement or function. Think of
 * the function node as last node that all the returning nodes point to.  So
 * the result of the function call is contained in the function node. *)
type t =
  | Statement of CilType.Stmt.t
  (** The statements as identified by CIL *)
  (* The stmt in a Statement node is misleading because nodes are program points between transfer functions (edges), which actually correspond to statement execution. *)
  | FunctionEntry of CilType.Fundec.t
  (** *)
  | Function of CilType.Fundec.t
  (** The variable information associated with the function declaration. *)
[@@deriving eq, ord, to_yojson]

let current_node: t option ref = ref None
