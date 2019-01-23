-module(test_happy).
-compile(export_all).

poi1Old() ->
	{'happy_old.erl',6,call,1}.
poi1New() ->
	{'happy_new.erl',{29,2},{29,16}}.
poi2Old() ->
	{'happy_old.erl',10,call,1}.
poi2New() ->
	{'happy_new.erl',21,call,1}.

rel1() ->
	[{poi1Old(),poi1New()}].
rel2() ->
	[{poi1Old(),poi1New()},{poi2Old(),poi2New()}].

funs() ->
	"[main/2]".

comp_perf(TO,TN) ->
	ZippedList = lists:zip(TO,TN), 
	lists:foldl(
		fun
			(_,{false,Msg}) ->
				{false,Msg};
			({{_,VO},{_,VN}},_) ->
				case VO of 
					VN ->
						true; 
					_ ->
						{false,"Bad Calculation"} 
				end
		end,
	true , 
	ZippedList).

config() ->
	secer_api:nuai_tr_config(mytecf(),ubrm()).

mytecf() ->
	fun(TO,TN) ->
		VEF = secer_api:vef_value_only(),
		case VEF(TO) == VEF(TN) of
			true ->
				true;
			false ->
				case secer_api:get_te_ca(TO) == secer_api:get_te_ca(TN) of
					true ->
						different_value_same_args;
					false ->
						different_value_different_args
				end
		end
	end.

ubrm() ->
	[{different_value_same_args,[val,ca]},{different_value_different_args,[val,ca]}].