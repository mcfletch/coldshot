from coldshot import profile

def a():
    for i in range( 8 ):
        for j in b():
            yield i,j
def b():
    for i in range( 8 ):
        yield i**2

@profile( 'generating.profile' )
def main():
    for x in a():
        print x
    
if __name__ == "__main__":
    main()
