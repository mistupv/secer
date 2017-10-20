-module(happy_old).
-export([main/2]).

-spec main(pos_integer(),pos_integer()) -> [pos_integer()].
main(N, M) -> 
	happy_list(N, M, []).

happy_list(_, N, L) when length(L) =:= N -> lists:reverse(L);
happy_list(X, N, L) -> 
	Happy = is_happy(X),
	if Happy -> happy_list(X + 1, N, [X|L]);
	true -> happy_list(X + 1, N, L) end.

is_happy(1) -> true;
is_happy(4) -> false;
is_happy(N) when N > 0 ->
	N_As_Digits = [Y - 48 || Y <- integer_to_list(N)],
	is_happy(lists:foldl(fun(X, Sum) -> (X * X) + Sum end, 0, N_As_Digits));
is_happy(_) -> false.