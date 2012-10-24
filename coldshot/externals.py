"""Top level (mainloop-like) operation"""
from . import profiler
import tempfile, runpy

__all__ = ('run','runctx')

def run( code, filename=None ):
    """Run exec-able code under the profiler
    
    code -- exec-able code (string, code, file) to run 
    filename -- if provided, write the profile into the given directory
        any previous profile in the directory will be deleted
        
    This is just a thin shim around runctx that provides empty dictionaries 
    for globals and locals.
    
    returns profiler.Profiler instance
    """
    return runctx( code, {}, {}, filename )
    
def runctx( code, globals=None, locals=None, prof_dir=None ):
    """Run exec-able code under the profiler
    
    code -- exec-able code (string, code, file) to run 
    globals -- if provided, a dictionary of globals in which to run 
    locals -- if provided, a dictionary of locals in which to run
    filename -- if provided, write the profile into the given directory
        any previous profile in the directory will be deleted.
        Note: the caller is responsible for cleanup of the directory,
        even if no filename is provided.
        
        try:
            prof = runctx( '2+3', {}, {} )
            # do something with prof...
        finally:
            shutil.rmtree( prof.writer.directory )
    
    returns profiler.Profiler instance (if execution was successful), or 
        raises any errors encountered in the execution
    """
    if prof_dir is None:
        prof_dir = tempfile.mkdtemp( prefix='coldshot-', suffix = '-profile' )
    if globals is None:
        globals = {}
    if locals is None:
        locals = globals 
    prof = profiler.Profiler( prof_dir )
    prof.start()
    try:
        exec code in globals, locals
    finally:
        prof.stop()
    return prof

def main():
    import os, sys
    from optparse import OptionParser
    usage = "coldshot output_directory scriptfile [arg] ...\n"
    try:
        output,scriptfile = sys.argv[1:3]
    except (TypeError,ValueError) as err:
        sys.stderr.write( usage )
        return 2
    sys.argv[:] = [scriptfile] + sys.argv[3:]
    sys.path.insert(0, os.path.dirname(scriptfile))
    with open(scriptfile, 'rb') as fp:
        code = compile(fp.read(), scriptfile, 'exec')
    globals = {
        '__file__': scriptfile,
        '__name__': '__main__',
        '__package__': None,
    }
    runctx(code, globals, None, output)
    return 0
