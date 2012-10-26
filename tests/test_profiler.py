from unittest import TestCase
from coldshot import profiler, loader 
import numpy, tempfile, os, shutil

def blah():
    return True

class TestProfiler( TestCase ):
    def setUp( self ):
        self.test_dir = tempfile.mkdtemp( prefix = 'coldshot-test' )
        self.profiler = profiler.Profiler( self.test_dir )
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
        self.profiler.start()
        for i in range(200):
            x.append( i )
        self.profiler.stop()
        assert self.profiler.files
        assert self.profiler.functions
        
        load = loader.Loader( self.test_dir )
        load.load()
        assert load.functions 
        assert ('__builtin__','range') in load.function_names, load.function_names.keys()
        assert ('__builtin__.list','append') in load.function_names, load.function_names.keys()
    
