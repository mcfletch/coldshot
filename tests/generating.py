from coldshot.cprofdecorator import profile

@profile
def a():
    for i in range( 8 ):
        for j in b():
            yield i,j
def b():
    for i in range( 8 ):
        yield i**2

for x in a():
    print x
    
