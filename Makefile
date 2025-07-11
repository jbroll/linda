
test: test-sh test-tcl test-py

test-sh:
	./test-linda.sh

test-tcl:
	tclsh test-linda.tcl
	
test-py:
	python3 test-linda.py

clean:
	rm -rf error.log __pycache__
