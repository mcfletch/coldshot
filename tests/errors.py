import time 
class Err( Exception ):
    "Some error"

class WithInit( object ):
    """With an init method"""
    def __init__( self ):
        time.sleep( 0.001 )

class WithoutInit( WithInit ):
    """Inherited init only"""

def a():
    time.sleep( 0.001 )
a() # called after *definition* of the exception

def b():
    time.sleep( 0.001 )

WithInit()

b()

def raises():
    WithInit()
    raise Err("hello")

def c():
    Err()
    WithInit()
    WithoutInit()
    try:
        raises()
    except Exception as err:
        pass 

c()
