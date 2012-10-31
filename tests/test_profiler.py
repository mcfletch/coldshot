from unittest import TestCase
from coldshot import profiler, loader 
import tempfile, os, shutil, time

def blah():
    return True

def sleep( t ):
    """A python function that takes a given amount of time"""
    time.sleep( t )
    
def slow_lines():
    """Each line here should have ~ the time assigned in the parameter"""
    time.sleep( .001 )
    time.sleep( .01 )
    time.sleep( .1 )
def slow_calls():
    """Each line here should have ~ the time assigned in the parameter"""
    sleep( .001 )
    sleep( .01 )
    sleep( .1 )

class TestProfiler( TestCase ):
    def setUp( self ):
        self.test_dir = tempfile.mkdtemp( prefix = 'coldshot-test' )
        self.profiler = profiler.Profiler( self.test_dir, lines=True )
    def tearDown( self ):
        self.profiler.stop()
        shutil.rmtree( self.test_dir, True )
        
    def test_test_setup( self ):
        pass
    def test_start( self ):
        self.profiler.start()
        blah()
        self.profiler.stop()
        load = loader.Loader( self.test_dir )
        load.load()
        assert load.files
        
        this_file = load.files[1]
        
        assert load.functions 
        for funcno, funcinfo in load.functions.items():
            assert funcinfo.name 
        this_key = ('tests.test_profiler','blah')
        assert this_key in load.function_names, load.function_names.keys()
        blah_func = load.function_names[this_key]
        assert blah_func.calls == 1
        assert blah_func.time

    def test_c_calls( self ):
        x = []
        y = []
        self.profiler.start()
        for i in range(200):
            x.append( i )
            y.append( i )
        self.profiler.stop()
        assert self.profiler.files
        assert self.profiler.functions
        
        load = loader.Loader( self.test_dir )
        load.load()
        assert load.functions 
        assert ('__builtin__','range') in load.function_names, load.function_names.keys()
        assert ('__builtin__.list','append') in load.function_names, load.function_names.keys()
        list_append = load.function_names[('__builtin__.list','append')]
        assert list_append.calls == 400, list_append.calls
    
    def test_line_timings_vs_calls( self ):
        self.profiler.start()
        slow_lines()
        slow_calls()
        self.profiler.stop()
        
        load = loader.Loader( self.test_dir )
        load.load()
        for name in ['slow_lines','slow_calls']:
            slow_func = load.function_names['tests.test_profiler',name]
            assert len(slow_func.line_map) == 4, slow_func.line_map # start + 3 internal lines
            sorted_lines = [x[1] for x in sorted( slow_func.line_map.items())][1:]
            multiplier = 1000000
            for line,(low,high) in zip(sorted_lines,[
                (.001,.002),
                (.01,.011),
                (.1,.101),
            ]):
                assert line.time > low * multiplier, line 
                assert line.time < high * multiplier, line 
            line_total = sum([ x.time for x in sorted_lines ])
            assert slow_func.time-line_total < .001*multiplier, (line_total, slow_func.time)
    def test_load_byteswapped( self ):
        self.profiler.start()
        for i in range(5):
            pass 
        self.profiler.stop()
        
        load = loader.Loader( self.test_dir )
        load.process_index( load.index_filename )
        load.swapendian = True 
        self.assertRaises( KeyError, load.process_calls )
        
        this_key = ('tests.test_profiler','test_load_byteswapped')
        assert this_key in load.function_names 
    
    def test_byteswap( self ):
        assert loader.byteswap_16( 0xff00 ) == 0xff,  loader.byteswap_16( 0xff00 )
        assert loader.byteswap_16( 0x00ff ) == 0xff00, loader.byteswap_16( 0x00ff )
        assert loader.byteswap_32( 0x89abcdef ) == 0xefcdab89, hex(loader.byteswap_32( 0x89abcdef ))
        
    def test_enter_exit( self ):
        with self.profiler:
            for i in range( 5 ):
                pass
        assert len(self.profiler.functions) == 2, self.profiler.functions
        self.profiler.close()
        load = loader.Loader( self.test_dir )
        load.load()
        this_key = ('tests.test_profiler','test_enter_exit')
        assert this_key in load.function_names, load.function_names
    
