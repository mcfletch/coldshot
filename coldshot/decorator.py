"""Just demonstrates a cProfile decorator, as Django folks are using Hotshot!"""
from . import profiler
from functools import wraps

__all__ = ['profile']

def profile( directory, **named ):
    """Decorator to profile a single function (on every call)
    
    directory -- the directory into which to store the coldshot profile
    named -- arguments passed to the coldshot.profiler.Profiler initializer
    
             lines -- if True, do line-level tracing (requires significantly more 
                 disk-space and processing time)
    
    @profile( '/path/to/directory', lines=True )
    def long_running_function( a,b,c ):
        '''The function to profile'''
    
    returns decorator to wrap the final method
    """
    prof = profiler.Profiler(directory, **named)
    def decorator( function ):
        @wraps( function )
        def final( *args, **named ):
            with prof:
                return function( *args, **named )
        return final 
    return decorator
