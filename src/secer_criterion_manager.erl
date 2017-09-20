-module(secer_criterion_manager).
-export([get_replaced_AST/4]).
-define(TMP_PATH,"./tmp/").


get_replaced_AST(FileI,Line,Var,Occurrence) -> 
	%POIs = get_poi(FileI,Line,Var,Occurrence),

	ModuleName = filename:basename(FileI,".erl"),
	{ok,AST_code} = epp:parse_file(FileI,[],[]),
	AtomVar = list_to_atom(Var),
	Final_AST = instrument_AST(AST_code,FileI,Line,AtomVar,Occurrence),
	{ok,Final_file} = file:open(?TMP_PATH++ModuleName++"Tmp.erl",[write]),
	generate_final_code(Final_AST,Final_file),

	compile:file(?TMP_PATH++ModuleName++"Tmp.erl",[{outdir,?TMP_PATH}]),
	code:purge(list_to_atom(ModuleName++"Tmp")),
	code:load_abs(?TMP_PATH++ModuleName++"Tmp").

generate_final_code(AST,File) ->
	lists:mapfoldl(fun revert_code/2,File,AST).

revert_code(Form,File) ->
	case erl_syntax:type(Form) of
		attribute ->
			Attr_name = erl_syntax:attribute_name(Form),
			case {erl_syntax:is_atom(Attr_name,file),erl_syntax:is_atom(Attr_name,module)} of
				{true,_} ->
					{empty,File};
				{_,true} ->
					{ok,Filename} = file:pid2name(File),
					ModuleName = filename:basename(Filename,".erl"),
					New_module = erl_syntax:attribute(Attr_name,[erl_syntax:atom(ModuleName)]),
					{io:format(File,"~s",[erl_pp:form(erl_syntax:revert(New_module))]),File};
				_ -> 
					{io:format(File,"~s",[erl_pp:form(erl_syntax:revert(Form))]),File}
			end;
		_ ->
			{io:format(File,"~s",[erl_pp:form(erl_syntax:revert(Form))]),File}
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% INSTRUMENTATION %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
instrument_AST(AST,File,Line,Sc_name,Oc) ->
	{New_AST,{_,_,_,Found}} = lists:mapfoldl(fun map_instrument_AST/2,{Line,Sc_name,Oc,false},AST),
	case Found of
		true ->
			ok;
		false ->
			io:format("No variable ~s occurrence ~p found in ~s line ~p\n",[Sc_name,Oc,File,Line]),
			secer ! die,
			exit(0)
	end,
	New_AST.

map_instrument_AST(Node,{Line,Sc_name,Oc,Found}) ->
	case erl_syntax:type(Node) of
		function ->
			SC_path = get_path(Node,Line,Sc_name,Oc),
			case SC_path of 
				unfound -> 
					{Node,{Line,Sc_name,Oc,Found}};
				_ -> 
					Ann_node = erl_syntax_lib:annotate_bindings(Node,ordsets:new()),
					Var_list = sets:to_list(erl_syntax_lib:variables(Node)),
					add_vars_to_var_gen(Var_list),
					{instrument(Ann_node,SC_path),{Line,Sc_name,Oc,true}}
			end;
		_ -> 
			{Node,{Line,Sc_name,Oc,Found}}
	end.

%%%%%%%%%%%%%%%%
%%% GET PATH %%%
%%%%%%%%%%%%%%%%
get_path(Root,Line,Sc_name,Oc) ->
	try 
		list_of_lists(erl_syntax:subtrees(Root),Line,Sc_name,Oc,1,[]),
		unfound
	catch
		Path -> Path
	end.
list_of_lists(L,Line,Sc_name,Oc,CurrentOc,Path) ->
	lists:foldl(
		fun(E, {Li,Sc,O,NAcc,CurOc}) ->
			{_,_,_,_,NewCurrentOc} = list(E,{Li,Sc,O,NAcc,CurOc},1,Path),
			{Li,Sc,O,NAcc + 1,NewCurrentOc}
		end,
		{Line,Sc_name,Oc,1,CurrentOc},
		L).
list(L,{Line,Sc_name,Oc,N,CurrentOc},_,Path) ->
	lists:foldl(
		fun(E, {Li,Sc,O,MAcc,CurOc}) ->
			New_path = [{erl_syntax:type(E),N,MAcc}|Path],
			case E of
				{var,Li,Sc} when O == CurOc -> 
					throw(New_path);
				{var,Li,Sc} ->
					{_,_,_,_,NewCurrentOc} = list_of_lists(erl_syntax:subtrees(E),Li,Sc,O,CurOc,New_path),
					{Li,Sc,O,MAcc+1,NewCurrentOc+1};
				_ ->
					{_,_,_,_,NewCurrentOc} =list_of_lists(erl_syntax:subtrees(E),Li,Sc,O,CurOc,New_path),
					{Li,Sc,O,MAcc+1,NewCurrentOc}
			end
		end,
		{Line,Sc_name,Oc,1,CurrentOc},
		L).

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% ADD VARS TO VAR GEN %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%
add_vars_to_var_gen([]) ->
	var_gen ! all_variables_added;
add_vars_to_var_gen([Var|Vars]) ->
	var_gen ! {add_variable,atom_to_list(Var)},
	add_vars_to_var_gen(Vars).

%%%%%%%%%%%%%%%%%%
%%% INSTRUMENT %%%
%%%%%%%%%%%%%%%%%%
instrument(Node,Path) -> 
	{Root_to_node,Node_to_sc} = divide_path(Path,[]),
	Instrumented_AST = sc_replacer(Node,{Root_to_node,Node_to_sc}),
	Instrumented_AST.

divide_path([],L2) ->
	{[],L2};
divide_path([Node|Father],[]) ->
	divide_path(Father,[Node]);
divide_path([{clause,N1,M1}|Father],[{Type,1,M2}|T]) -> % PATTERN
	divide_path(Father,[{clause,N1,M1}|[{Type,1,M2}|T]]);
divide_path([{clause,N1,M1}|Father],[{Type,2,M2}|T]) -> % GUARD
	divide_path(Father,[{clause,N1,M1}|[{Type,2,M2}|T]]);
divide_path([Node|Father],L2) ->
 	case Node of
 		{match_expr,_,_} -> 
 			{lists:reverse([Node|Father]),L2};
 		{clause,_,_} -> 
 			{lists:reverse([Node|Father]),L2};
 		{list_comp,_,_} -> 
 			{lists:reverse([Node|Father]),L2};
 		{case_expr,_,_} -> 
 			{lists:reverse([Node|Father]),L2};
 		{try_expr,_,_} ->
 			{lists:reverse([Node|Father]),L2};
 		{receive_expr,_,_} ->
 			{lists:reverse([Node|Father]),L2};
 		{if_expr,_,_} ->
 			{lists:reverse([Node|Father]),L2};
 		{_,_,_} ->
 			divide_path(Father,[Node|L2])
 	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% CASE WITH THE INSTRUMENTED EXPRESSIONS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
sc_replacer(Node,{[],Node_to_sc}) ->
	replace_expression_with_clauses(Node,Node_to_sc);
sc_replacer(Node,{[{Type,N,M}],Node_to_sc}) ->
	Children = erl_syntax:subtrees(Node),
	Child = lists:nth(N,Children),
	Elem = lists:nth(M,Child),

	New_elem = 	case Type of
					match_expr ->
						replace_match(Elem,Node_to_sc);
					list_comp ->
						replace_lc(Elem,Node_to_sc);
					_ ->
						replace_expression_with_clauses(Elem,Node_to_sc)
				end,

	New_child = replacenth(M,New_elem,Child),
	New_children = replacenth(N,New_child,Children),
	erl_syntax:make_tree(erl_syntax:type(Node),New_children);

sc_replacer(Node,{[{_,N,M}|T],Node_to_sc}) ->
	Children = erl_syntax:subtrees(Node),
	Child = lists:nth(N,Children),
	Elem = lists:nth(M,Child),

	New_elem = sc_replacer(Elem,{T,Node_to_sc}),

	New_child = replacenth(M,New_elem,Child),
	New_children = replacenth(N,New_child,Children),
	erl_syntax:make_tree(erl_syntax:type(Node),New_children).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% REPLACE SC IN DIFFERENT STRUCTURES %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%
% MATCHES %
%%%%%%%%%%%	
replace_match(Node,[{Type,N,M}|T]) ->
	case N of
		1 -> 
			replace_match_pattern(Node,[{Type,N,M}|T]);
		_ ->
			replace_expression(Node,[{Type,N,M}|T])
	end.

replace_match_pattern(Node,[{Type,N,M}|T]) -> 
	Children = erl_syntax:subtrees(Node),
	Child = lists:nth(N,Children),

	{[New_pattern],Var_sc_fv} = replace_pattern_with_free_variables(Child,[{Type,N,M}|T],dict:new()),

	Expr_pm = erl_syntax:match_expr(New_pattern,erl_syntax:match_expr_body(Node)),
	
	%Var_sc_fv = erlang:get(slicing_criterion),
	Node_sc = obtain_sc(Node,[{Type,N,M}|T]),

	Ann = erl_syntax:get_ann(Node),
	[_,_,{free,Bounded_vars}] = Ann,

	Sc_name = erl_syntax:variable_name(Node_sc),

	Expr_block = case lists:member(Sc_name,Bounded_vars) of
		true ->	
			Expr_send_sc = erl_syntax:infix_expr(erl_syntax:atom("tracer"),erl_syntax:operator("!"),
								erl_syntax:tuple([erl_syntax:atom(add),Node_sc])),
			erl_syntax:block_expr([Expr_pm,Expr_send_sc,New_pattern]);
		false ->
			Expr_send_fv = erl_syntax:infix_expr(erl_syntax:atom("tracer"),erl_syntax:operator("!"),
								erl_syntax:tuple([erl_syntax:atom(add),Var_sc_fv])),
			erl_syntax:block_expr([Expr_pm,Expr_send_fv,New_pattern])
	end,
	erl_syntax:match_expr(erl_syntax:match_expr_pattern(Node),Expr_block).

%%%%%%%%%%%%%%%%%%%%%%%
% LIST COMPREHENSIONS %
%%%%%%%%%%%%%%%%%%%%%%%
replace_lc(Node,[{generator,N1,M1},{Type,N2,M2}|T]) ->
	Children = erl_syntax:subtrees(Node),
	Child = lists:nth(N1,Children),
	Elem = lists:nth(M1,Child),

	New_generator = replace_generator(Elem,[{Type,N2,M2}|T]),

	Final_child = case N2 of 
		1 -> 
			New_child = replacenth(M1,New_generator,Child),
			New_generator_aux = add_neccessary_generator(Elem,[{Type,N2,M2}|T],erl_syntax:generator_pattern(New_generator)),
			add_at_nth(New_generator_aux,M1+1,1,New_child,[]);
		_ -> 
			replacenth(M1,New_generator,Child)
	end,

	New_children = replacenth(N1,Final_child,Children),
	erl_syntax:make_tree(erl_syntax:type(Node),New_children);

replace_lc(Node,Path) -> 
 	replace_expression(Node,Path).

replace_generator(Node,[{Type,N,M}|T]) ->
	case N of
		1 -> % GENERATOR PATTERN
			[New_pattern] = replace_novar_pattern_with_free_variables([erl_syntax:generator_pattern(Node)],[{Type,N,M}|T]),
			erl_syntax:generator(New_pattern,erl_syntax:generator_body(Node));
		_ ->
			replace_expression(Node,[{Type,N,M}|T])
	end.

add_neccessary_generator(Node,[{Type,N,M}|T],New_pattern) ->
	Old_pattern = erl_syntax:generator_pattern(Node),
	case N of
		1 ->
			Node_sc = obtain_sc(Node,[{Type,N,M}|T]),
			Expr_send_sc = erl_syntax:infix_expr(erl_syntax:atom("tracer"),erl_syntax:operator("!"),
			 					erl_syntax:tuple([erl_syntax:atom(add),Node_sc])),
			Expr_list_gen = erl_syntax:list([New_pattern]),
			Gen_Body = erl_syntax:block_expr([Expr_send_sc,Expr_list_gen]),

			erl_syntax:generator(Old_pattern,Gen_Body);
		 _ -> 
		 	throw("ERROR ADDING GENERATOR IN LC")
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% EXPRESSIONS WITH CLAUSES %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% CASE, IF, FUNCTION, TRYOF-CATCH, RECEIVE, GUARDS %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
replace_expression_with_clauses(Node,[{clause,N1,M1},{Type,N2,M2}|T]) ->
	Node_type = erl_syntax:type(Node),

	Children = erl_syntax:subtrees(Node),
	Child = lists:nth(N1,Children),
	Elem = lists:nth(M1,Child),

	Clauses = get_node_clauses(Node,N1,M1),

	New_clause = case {Type,N2} of
		{disjunction,_} -> 
			replace_guard(Elem,[{Type,N2,M2}|T],Clauses,Node_type);
		{_,1} -> 
			replace_clause(Elem,[{Type,N2,M2}|T],Clauses,Node_type);
		_ ->
			replace_expression(Elem,[{Type,N2,M2}|T])
	end,
	
	New_child = generate_new_child(Node_type,M1,New_clause,Child),
	New_children = replacenth(N1,New_child,Children),
	erl_syntax:make_tree(Node_type,New_children);
replace_expression_with_clauses(Node,[{Type,N,M}|T]) ->
	replace_expression(Node,[{Type,N,M}|T]).

get_node_clauses(Node,N,M) -> 
	case erl_syntax:type(Node) of
		function ->
			Clauses = erl_syntax:function_clauses(Node),
			Lasts = lists:nthtail(M-1,Clauses),
			adapt_function_patterns(Lasts,[]);
		case_expr ->	
			Clauses = erl_syntax:case_expr_clauses(Node),
			lists:nthtail(M-1,Clauses);
		receive_expr ->
			Clauses = erl_syntax:receive_expr_clauses(Node),
			lists:nthtail(M-1,Clauses);
		try_expr ->
			Clauses = case N of
				2 -> erl_syntax:try_expr_clauses(Node);
				3 -> erl_syntax:try_expr_handlers(Node)
			end,
			lists:nthtail(M-1,Clauses);
		if_expr ->
			Clauses = erl_syntax:if_expr_clauses(Node),
			Lasts = lists:nthtail(M-1,Clauses),
			add_pattern(Lasts,[]);
		_ ->
			throw("Uncontempled type of node")
	end.

adapt_function_patterns([],New_clauses) -> 
	lists:reverse(New_clauses);
adapt_function_patterns([Clause|Clauses],New_clauses) ->
	Old_pattern = erl_syntax:clause_patterns(Clause),
	New_clause = erl_syntax:clause([erl_syntax:tuple(Old_pattern)],erl_syntax:clause_guard(Clause),erl_syntax:clause_body(Clause)),
	adapt_function_patterns(Clauses,[New_clause|New_clauses]).

add_pattern([],New_clauses) -> 
	lists:reverse(New_clauses);
add_pattern([Clause|Rest],New_clauses) ->
	New_clause = erl_syntax:clause([erl_syntax:underscore()],erl_syntax:clause_guard(Clause),erl_syntax:clause_body(Clause)),
	add_pattern(Rest,[New_clause|New_clauses]).

generate_new_child(Type,M,New_clause,Child) ->
	case Type of
		if_expr -> 
			{New_clauses,_} = lists:split(M,Child),
			replacenth(M,New_clause,New_clauses);
		_ -> 
			replacenth(M,New_clause,Child)
	end.

%%%%%%%%%%
% GUARDS %
%%%%%%%%%%
% <=== TODO ===>
% ESTA FUNCION RECOGE EL VALOR DE TODAS LAS VARIABLES DE LA GUARDA SE EVALUEN 
% O NO (IGNORA CORTOCIRCUITADOS)
% <============>
replace_guard(Node,Path,Clauses,Root_type) ->	
	Node_sc = obtain_sc(Node,Path),
	Expr_send_sc = erl_syntax:infix_expr(erl_syntax:atom("tracer"),erl_syntax:operator("!"),
								erl_syntax:tuple([erl_syntax:atom(add),Node_sc])),
	
	Pattern = erl_syntax:clause_patterns(Node),
	Expr_case = generate_case_expression(Pattern,Clauses,Root_type), 

	Expr_block = erl_syntax:block_expr([Expr_send_sc,Expr_case]),
	erl_syntax:clause(erl_syntax:clause_patterns(Node),[],[Expr_block]).

%%%%%%%%%%%
% CLAUSES %
%%%%%%%%%%%
replace_clause(Node,[{Type,N,M}|T],Clauses,Root_type) ->
	Children = erl_syntax:subtrees(Node),
	Child = lists:nth(N,Children),

	%REPLACE PATTERN
	{New_pattern,Var_sc_fv} = replace_pattern_with_free_variables(Child,[{Type,N,M}|T],dict:new()),

	%CREATE BODY
	%Var_sc_fv = erlang:get(slicing_criterion),
	Node_sc = obtain_sc(Node,[{Type,N,M}|T]),

	Ann = erl_syntax:get_ann(Node),
	[_,_,{free,Bounded_vars}] = Ann,

	Sc_name = erl_syntax:variable_name(Node_sc),

	Expr_block = case lists:member(Sc_name,Bounded_vars) of
		true ->	
			Expr_send_fv = erl_syntax:infix_expr(erl_syntax:atom("tracer"),erl_syntax:operator("!"),
									erl_syntax:tuple([erl_syntax:atom(add),Var_sc_fv])),
			Expr_send_sc = erl_syntax:infix_expr(erl_syntax:atom("tracer"),erl_syntax:operator("!"),
									erl_syntax:tuple([erl_syntax:atom(add),Node_sc])),
			Case_clause_equal = erl_syntax:clause([Node_sc],[],[Expr_send_fv]),
			Case_clause_else = erl_syntax:clause([erl_syntax:underscore()],[],[Expr_send_sc]),
			Expr_tracer_case = erl_syntax:case_expr(Var_sc_fv,[Case_clause_equal,Case_clause_else]),
			
			Expr_clauses_case = generate_case_expression(New_pattern,Clauses,Root_type),
			erl_syntax:block_expr([Expr_tracer_case,Expr_clauses_case]);
		_ ->
			Expr_send_fv = erl_syntax:infix_expr(erl_syntax:atom("tracer"),erl_syntax:operator("!"),
									erl_syntax:tuple([erl_syntax:atom(add),Var_sc_fv])),
			Expr_case = generate_case_expression(New_pattern,Clauses,Root_type),
			erl_syntax:block_expr([Expr_send_fv,Expr_case])
	end,

	%CREATE CLAUSE
	erl_syntax:clause(New_pattern,[],[Expr_block]).

generate_case_expression(Pattern,Clauses,Type) ->
	case Type of
		function -> 
			erl_syntax:case_expr(erl_syntax:tuple(Pattern),Clauses);
		if_expr ->
			erl_syntax:case_expr(erl_syntax:atom("empty_expression"),Clauses);
		try_expr ->
			[Pattern0] = Pattern,
			Is_pattern_class_qualifier = erl_syntax:type(Pattern0) == class_qualifier,
			Are_catch_patterns = lists:any(
									fun(Elem) -> 
										[Clause_pattern] = erl_syntax:clause_patterns(Elem),
										erl_syntax:type(Clause_pattern) == class_qualifier
									end,
									Clauses),
			Are_special_patterns = Is_pattern_class_qualifier or Are_catch_patterns,
			{New_pattern,New_clauses} = case Are_special_patterns of
				true -> 
					{generate_new_catch_pattern(Pattern),generate_new_catch_clauses(Clauses,[])};
				false ->
					{Pattern0,Clauses}
			end,
			erl_syntax:case_expr(New_pattern,New_clauses);
			
		_ -> 
			[New_pattern] = Pattern,
			erl_syntax:case_expr(New_pattern,Clauses)
	end.

generate_new_catch_pattern([Pattern]) ->
	case erl_syntax:type(Pattern) of
		class_qualifier ->
			Elem1 = erl_syntax:class_qualifier_argument(Pattern),
			Elem2 = erl_syntax:class_qualifier_body(Pattern),
			erl_syntax:tuple([Elem1,Elem2]);
		_ ->
			Elem1 = erl_syntax:underscore(),
			erl_syntax:tuple([Elem1,Pattern])
	end.

generate_new_catch_clauses([],New_clauses) ->
	lists:reverse(New_clauses);
generate_new_catch_clauses([Clause|Clauses],New_clauses) ->
	[Pattern] = erl_syntax:clause_patterns(Clause),
	New_pattern = case erl_syntax:type(Pattern) of
		class_qualifier ->
			Elem1 = erl_syntax:class_qualifier_argument(Pattern),
			Elem2 = erl_syntax:class_qualifier_body(Pattern),
			erl_syntax:tuple([Elem1,Elem2]);
		_ ->
			Elem1 = erl_syntax:underscore(),
			erl_syntax:tuple([Elem1,Pattern])
	end,

	New_clause = erl_syntax:clause([New_pattern],erl_syntax:clause_guard(Clause),erl_syntax:clause_body(Clause)),
	generate_new_catch_clauses(Clauses,[New_clause|New_clauses]).

%%%%%%%%%%%%%%%
% EXPRESSIONS %
%%%%%%%%%%%%%%%
replace_expression(Node,[{_,N,M}|T]) ->
	Children = erl_syntax:subtrees(Node),
	Child = lists:nth(N,Children),
	Elem = lists:nth(M,Child),
	
	Replaced_expression = case T of
		[] ->
			Expr_send = erl_syntax:infix_expr(erl_syntax:atom("tracer"),erl_syntax:operator("!"),
									erl_syntax:tuple([erl_syntax:atom(add),Elem])),
			erl_syntax:block_expr([Expr_send,Elem]);
		_ ->
			replace_expression(Elem,T)
	end,
	
	New_child = replacenth(M,Replaced_expression,Child),
	New_children = replacenth(N,New_child,Children),
	erl_syntax:make_tree(erl_syntax:type(Node),New_children).

%%%%%%%%%%
% COMMON %
%%%%%%%%%%
replace_pattern_with_free_variables(Pattern,[{_,_,M}],VarDic) -> % DEVUELVE EN FORMATO [Pattern1,Pattern2...]
	{Modified_pattern,_} = replace_after_position(Pattern,M,VarDic),
	Sc_fv = gen_and_put_scFreeVar(),
	{replacenth(M,Sc_fv,Modified_pattern),Sc_fv};
replace_pattern_with_free_variables(Pattern,[{_Type1,_N1,M1},{_Type,N,M2}|T],VarDic) ->
	{New_pattern,NewDic} = replace_after_position(Pattern,M1,VarDic),
	
	Sc_elem = lists:nth(M1,New_pattern),
	Children = erl_syntax:subtrees(Sc_elem),
	Child = lists:nth(N,Children),

	{New_child,Sc_fv} = replace_pattern_with_free_variables(Child,[{_Type,N,M2}|T],NewDic),
	
	Final_children = replacenth(N,New_child,Children),
	{replacenth(M1,erl_syntax:make_tree(erl_syntax:type(Sc_elem),Final_children),New_pattern),Sc_fv}.

gen_and_put_scFreeVar() ->
	var_gen ! {get_free_variable,self()},
	New_var = receive
				FV -> FV
			  end,
	%erlang:put(slicing_criterion,New_var),
	New_var.

obtain_sc(Node,[]) -> 
	Node;
obtain_sc(Node,[{_,N,M}|T]) ->
	Children = erl_syntax:subtrees(Node),
	Child = lists:nth(N,Children),
	Elem = lists:nth(M,Child),
	obtain_sc(Elem,T).

%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% REPLACE PATTERN LC %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%
replace_novar_pattern_with_free_variables(Pattern,[{_,_,M}]) -> % DEVUELVE EN FORMATO [Pattern1,Pattern2...]
	New_Pattern = replace_all_after_position(Pattern,M),
	NewSC = gen_and_put_scFreeVar(),
	replacenth(M,NewSC,New_Pattern);
replace_novar_pattern_with_free_variables(Pattern,[{_,_,M1},{_Type,N,M2}|T]) ->
	New_pattern = replace_all_after_position(Pattern,M1),

	Sc_elem = lists:nth(M1,New_pattern),
	Children = erl_syntax:subtrees(Sc_elem),
	Child = lists:nth(N,Children),

	New_child = replace_novar_pattern_with_free_variables(Child,[{_Type,N,M2}|T]),

	Final_children = replacenth(N,New_child,Children),
	replacenth(M1,erl_syntax:make_tree(erl_syntax:type(Sc_elem),Final_children),New_pattern). % CAMBIAR TAMBIEN EN EL OTRO REPLACE PATTERN

replace_all_after_position(List,Index) ->
	replace_all_after_position(List,Index,[],1).

replace_all_after_position([],_,New_list,_) ->
	lists:reverse(New_list);
replace_all_after_position([H|T],Index,New_list,Pos) ->
	case Pos > Index of
		true ->
			New_H = gen_free_var(),
			replace_all_after_position(T,Index,[New_H|New_list],Pos+1);
		false ->
			replace_all_after_position(T,Index,[H|New_list],Pos+1)
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% MISCELANEA %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% REPLACE NTH ELEMENT %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%
replacenth(Index,Value,List) ->
 replacenth(Index-1,Value,List,[],0).

replacenth(ReplaceIndex,Value,[_|List],Acc,ReplaceIndex) ->
 lists:reverse(Acc)++[Value|List];
replacenth(ReplaceIndex,Value,[V|List],Acc,Index) ->
 replacenth(ReplaceIndex,Value,List,[V|Acc],Index+1).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% REPLACE AFTER THE NTH ELEMENT %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
replace_after_position(List,Index,VarDic) ->
	replace_after_position(List,Index,[],1,VarDic).

replace_after_position([],_,New_list,_,VarDic) ->
	{lists:reverse(New_list),VarDic};
replace_after_position([H|T],Index,New_list,Pos,Dic) -> %REVISAR QUE HACER CUANDO POS = INDEX, NO CAMBIAR YA QUE SE TRATA A POSTERIORI
	case Pos > Index of
		true ->
			replace_after_position(T,Index,[gen_free_var()|New_list],Pos+1,Dic); %REPLACE WITH THE FREE VAR GENERATOR CALL
		false ->
			{NewH,NewDic} = erl_syntax_lib:mapfold(
				fun(Node,Dict) ->
					case erl_syntax:type(Node) of
						variable ->
							Ann = erl_syntax:get_ann(H),
							Bounded_vars = case Ann of
								[{env,Bounded},_,_] ->
									Bounded;
								[] ->
									[]
							end,
							VarName = erl_syntax:variable_name(Node),
							case lists:member(VarName,Bounded_vars) of
								true ->
									{Node,Dict};
								false ->
									Bool = dict:fold(
										fun(_,V,Acc) ->
											case Node of
												V ->
													true;
												_ ->
													false or Acc
											end
										end,
										false,
										Dict),
									case Bool of
										true ->
											{Node,Dict};
										false ->
											gen_free_var_before_sc(Node,Dict)
									end
							end;
						_ ->
							{Node,Dict}
					end
				end,
				Dic,
				H),
			replace_after_position(T,Index,[NewH|New_list],Pos+1,NewDic)
	end.

gen_free_var() ->
	var_gen ! {get_free_variable,self()},
	receive
		FV -> FV
	end.

gen_free_var_before_sc(Var,Dic) ->
	Var_name = erl_syntax:variable_name(Var),
	case dict:find(Var_name,Dic) of
		error ->
			New_var = gen_free_var(),
			New_dic = dict:store(Var_name,New_var,Dic),
			{New_var,New_dic};
		{ok,Value} ->
			{Value,Dic}
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% ADD AT NTH POSITION %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%
add_at_nth(_,_,_,[],New_list) -> lists:reverse(New_list);
add_at_nth(New_element,Add_index,Add_index,[Elem|List],New_list) ->
	add_at_nth(New_element,Add_index,Add_index+1,List,[Elem,New_element|New_list]);
add_at_nth(New_element,Add_index,Index,[Elem|List],New_list) ->
	add_at_nth(New_element,Add_index,Index+1,List,[Elem|New_list]).

%%%%%%%%%%%%%%%%%%%%%%%%%
%%% DEBUGGING PURPOSE %%%
%%%%%%%%%%%%%%%%%%%%%%%%%
% printer(Node) -> io:format("~p\n",[Node]).
% printers(Node) -> io:format("~s\n",[erl_prettypr:format(Node)]).
% printList([]) -> 
% 	theEnd;
% printList([H|T]) ->
% 	printer(H),
% 	printer("<=============>"),
% 	printList(T).
% printLists([]) -> 
% 	printer("<=============>"),
% 	theEnd;
% printLists([H|T]) ->
% 	printers(H),
% 	printLists(T).