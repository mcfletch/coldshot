"""Top level (mainloop-like) operations"""
from . import profiler, loader, reporter
import tempfile, atexit, sys
from optparse import OptionParser

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
    prof = profiler.Profiler( prof_dir, lines=lines )
    atexit.register( prof.stop )
    prof.start()
    try:
        exec code in globals, locals
    finally:
        prof.stop()
    return prof

def profile_options( ):
    """Create an option parser for the main profile operation"""
    usage = "coldshot -o output_directory path/to/scriptfile [arg] ..."
    parser = OptionParser( usage )
    parser.add_option( 
        '-o', '--output', dest='output', metavar='DIRECTORY', default='.profile',
        help='Directory to which to write output (file index.profile will be created here)',
    )
    parser.add_option(
        '-l', '--lines', dest='lines',
        action = 'store_true',
        default = False,
        help='Perform line-level tracing (requires an extra 2.5MB/s of disk space)',
    )
    # 
    parser.disable_interspersed_args()
    return parser
    
def profile(args=None):
    """Primary external entry point for profiling 
    
    $ coldshot -o outdirectory scriptfile [arg ... ]
    
    Note: this command line is currently too simplistic, as it can wind up 
    mis-interpreting the arguments if you happen to forget the outdirectory.
    """
    import os, sys
    parser = profile_options()
    options,args = parser.parse_args(args or sys.argv)
    args = args[1:]
    
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

def report_options( ):
    """Create an option parser for the main profile operation"""
    usage = "coldshot-report [options] output_directory\n"
    parser = OptionParser( usage )
    parser.add_option( 
        '-o', '--output', dest='output', metavar='DIRECTORY', default='.profile',
        help='Directory to which to write output (file index.profile will be created here)',
    )
    return parser

def report():
    """Load the data-set and print a basic report"""
    load = loader.Loader( sys.argv[1] )
    load.load()
    report = reporter.Reporter( load )
    print report.report()
    return 0

def raw_calls():
    """Load the data-set and print each record as a python dictionary"""
    scanner = loader.CallsFile( sys.argv[1] )
    for line in scanner:
        print line
