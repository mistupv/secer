# SecEr

SecEr is a tool for Erlang able to automatically generate a test suite that checks the behaviour of a point of interest. It can be used for regression testing, by generating a test suite for a future comparison or by automatically comparing two releases of an Erlang module. Defining one point of interest for each module the tool compares all the values taken by both points of interest, notifying the user of any mismatching result.

This tool provides a new granularity level of tracing, any variable of the code can be traced whether it is in a pattern, a guard or simply inside an expression.

SecEr implements a communication between Erlang modules and tools such as [TypEr](https://github.com/erlang/typer), [PropEr](https://github.com/manopapad/proper), and [CutEr](https://github.com/aggelgian/cuter). This means that SecEr handles the output of each tool and connects it with the next tool, taking advantage of the combined potential of the tools.

<!--Note: Our tool implements the module typer_mod.erl with several modifications over the typer.erl stardard library module (in the dialyzer library). This implementation performs some calls to the typer.erl module. This module can present differences between Erlang versions and this could lead to unexpected execution errors. SecEr has been implemented and tested with the Erlang version 19.2.3, and the typer version 0.9.11.-->

In the rest of this document we describe the main features and functionality of SecEr.

Installation
============
SecEr makes use of the Erlang modules and tools [TypEr](https://github.com/erlang/typer), [PropEr](https://github.com/manopapad/proper), and [CutEr](https://github.com/aggelgian/cuter), so there are some prerequisites to use it.
In order to perform a correct execution of the tool, all [CutEr](https://github.com/aggelgian/cuter) dependencies need to be fulfiled ([CutEr dependencies](https://github.com/aggelgian/cuter/blob/master/README.md)). 

	$ git clone --recursive https://github.com/serperu/secer.git
	$ cd secer/
	$ make 

The first step clones the GitHub's repository content to the local system. Then, `make` is used to compile PropEr, CutEr and SecEr source files, leaving the tool ready to run.

Usage
=====

There are two ways of running the tool, both considered in the command

    ./secer -pois "LIST_OF_POIS" [-funs "INPUT_FUNCTIONS"] -to TIMEOUT 
           [-cfun "COMPARISON_FUN"]

If we want to run the command to only generate a test suite, we need to provide a list of POIs (LIST_OF_POIS) contained in double quotes, a list of initial functions (INPUT_FUNCTIONS) also between double quotes, and a timeout (TIMEOUT). On the other hand, if we want to perform a comparison of two Erlang files we just need to provide a list of related POIs from both programs.

Example
=======
Consider the files `happy_old.erl` (with point of interest `{'happy_old.erl',10,{var,'Happy'},1}`) and `happy_new.erl` (with point of interest `{'happy_new.erl',21,'call',1}`) as two versions of the same program. 

For a single file test generation with the function `main/2` as input and a timeout of 15 seconds, the secer command would be used as follows:
	
    $ ./secer -pois "[{{'happy_old.erl',10,{var,'Happy'},1}}]"
              -funs "[main/2]" -to 15

The result shows the number of tests generated by the tool, divided in tests executing the point of interest and tests not executing the point of interes. All the tests generated by the tool are saved in a file:

	Function: main/2
	----------------------------
	Generated tests: 272
	Executing the point of interest: 272
	Results saved in: ./results/main_2.txt
	----------------------------

On the other hand, if we execute the command comparing both files (`happy_old.erl`,`happy_new.erl`), secer would be used as follows:

    $ ./secer -pois "[{{'happy_old.erl',10,{var,'Happy'},1},{'happy_new.erl',21,'call',1}}]"
              -funs "[main/2]" -to 15

In this case, the tool generates test cases by generating inputs for the specified functions and it compares the values taken by the defined points of interest. If there is no mismatching test the tool will show a message similar to

	Function: main/2
	----------------------------
	Generated tests: 320
	Both versions of the program generate identical traces for the defined points of interest
	----------------------------

describing the number of tests generated for the function and notifying the user that the behaviour was the same in both versions.

Otherwise, if any test mismatches, the message shown will be similar to

	Function: main/2
	----------------------------
	Generated tests: 272
	Mismatching tests: 21 (7.72%)
	POIs comparison:
        + {{'happy0.erl',10,{var,'Happy'},1},{'happy1.erl',21,call,1}} => 21 Errors
	All mismatching results were saved at: ./results/main_2.txt 
	--- First error detected ---
	Call: main(4,2)
	Error detected: Unexpected trace value
	POI: ({'happy0.erl',10,{var,'Happy'},1}) trace:
	    [false ,false ,false ,true ,false ,false ,true]
	POI: ({'happy1.erl',21,call,1}) trace:
	    [false ,false ,false ,false ,false ,false ,true ,false ,false ,true]
	----------------------------

describing the number of generated tests, the number of mismatching tests and the first mismatching test found by the tool, with the values taken by both traces of the point of interest. All mismatching tests will be saved in the specified file.

