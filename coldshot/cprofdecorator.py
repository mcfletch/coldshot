"""Just demonstrates a cProfile decorator, as Django folks are using Hotshot!"""
import cProfile
from functools import wraps
import time

def profile( statsfile ):
    """Profile into given statsfile"""
    prof = cProfile.Profile()
    def decorator( function ):
        @wraps( function )
        def final( *args, **named ):
            prof.enable()
            try:
                return function( *args, **named )
            finally:
                prof.disable()
                # yes, we re-write them on every call...
                prof.dump_stats( statsfile )
        return final 
    return decorator

@profile( 'test.profile' )
def test():
    time.sleep( 0.001 )

def main():
    for i in range( 20 ):
        test()

if __name__ == "__main__":
    main()
