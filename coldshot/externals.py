"""Top level (mainloop-like) operations"""
from . import profiler, loader, reporter, eventsfile
import tempfile, atexit, sys
from optparse import OptionParser
try:
    unicode 
except NameError:
    unicode = str 
else:
    bytes = str
def as_8_bit( u ):
    if isinstance( u, unicode ):
        return u.encode( 'utf-8' )
    return u

__all__ = ('run','runctx')

def run( code, filename=None, lines=False ):
    """Run exec-able code under the profiler
    
    code -- exec-able code (string, code, file) to run 
    filename -- if provided, write the profile into the given directory
        any previous profile in the directory will be deleted
        
    This is just a thin shim around runctx that provides empty dictionaries 
    for globals and locals.
    
    returns profiler.Profiler instance
    """
    return runctx( code, {}, {}, filename, lines=lines )
    
def runctx( code, globals=None, locals=None, prof_dir=None, lines=False ):
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
    prof = profiler.Profiler( as_8_bit(prof_dir), lines=lines )
    atexit.register( prof.stop )
    prof.start()
    try:
        exec( code, globals, locals )
    finally:
        prof.stop()
    return prof

def profile_options( ):
    """Create an option parser for the main profile operation"""
    usage = "%prog -o output_directory path/to/scriptfile [arg] ..."
    description = """Profile a script under the Coldshot profiler,
produces a directory of profile information, overwriting any 
existing profile information in doing so.

Coldshot produces a very large trace (1.5 to 4MB/s), 
so it should not be run on long-running processes."""
    parser = OptionParser( 
        usage=usage, add_help_option=True, description=description,
    )
    parser.add_option( 
        '-o', '--output', dest='output', metavar='DIRECTORY', default='.profile',
        help='Directory to which to write output (file index.coldshot will be created here)',
    )
    parser.add_option(
        '-l', '--lines', dest='lines',
        action = 'store_true',
        default = False,
        help='Perform line-level tracing (requires an extra 2.5MB/s of disk space)',
    )
    parser.disable_interspersed_args()
    return parser
    
def profile_main():
    """Primary external entry point for profiling 
    
    $ coldshot -o outdirectory scriptfile [arg ... ]
    
    Note: this command line is currently too simplistic, as it can wind up 
    mis-interpreting the arguments if you happen to forget the outdirectory.
    """
    import os, sys
    parser = profile_options()
    options,args = parser.parse_args()
    
    if not args:
        parser.error( "Need a script-file to execute" )
        return 1
    scriptfile = args[0]
    sys.argv[:] = args
    sys.path.insert(0, os.path.dirname(scriptfile))
    with open(scriptfile, 'rb') as fp:
        code = compile(fp.read(), scriptfile, 'exec')
    globals = {
        '__file__': scriptfile,
        '__name__': '__main__',
        '__package__': None,
    }
    runctx(code, globals, None, prof_dir=options.output, lines=options.lines)
    return 0

def report_main():
    """Load the data-set and print a basic report"""
    load = loader.Loader( sys.argv[1] )
    load.load()
    report = reporter.Reporter( load )
    print( report.report() )
    return 0

def raw_options():
    usage = """%prog [options]"""
    description = """Print out raw event records from a coldshot data-file/directory"""
    parser = OptionParser( 
        usage=usage, add_help_option=True, description=description,
    )
    parser.add_option( 
        '-i', '--input', dest='input', metavar='DIRECTORY', default='.profile',
        help='Directory from which to read',
    )
    parser.add_option(
        '-s', '--start', dest='start', metavar='INTEGER', default=0,
        type="int",
    )
    parser.add_option(
        '-S', '--stop', dest='stop', metavar='INTEGER', default=None,
        type="int",
    )
    return parser

    
def raw_events_main():
    """Load the data-set and print each record as a python dictionary"""
    parser = raw_options()
    options,args = parser.parse_args()
    if args:
        options.input = args[0]
        args = args[1:]
    scanner = eventsfile.EventsFile( options.input )
    
    depth = 0
    for line in scanner[options.start:(options.stop or scanner.record_count)]:
        if line['flags'] == 1:
            depth += 1
        print( '%s%s'%( ' '*depth,line ) )
        if line['flags'] == 2:
            depth -= 1
        if depth < 0:
            depth = 0
