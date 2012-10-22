from unittest import TestCase
from coldshot.profiler import Profiler
from coldshot.loader import Loader
import numpy, tempfile, os, shutil

def blah():
    return True

class TestProfiler( TestCase ):
    def setUp( self ):
        self.test_dir = tempfile.mkdtemp( prefix = 'coldshot-test' )
        self.profiler = Profiler( self.test_dir )
    def tearDown( self ):
        self.profiler.stop()
        shutil.rmtree( self.test_dir, True )
        
    def test_create( self ):
        pass 
    def test_start( self ):
        self.profiler.start()
        blah()
        self.profiler.stop()
        loader = Loader( self.test_dir )
        
        assert loader.files
        assert len(loader.files) == 1, loader.files 
        
        assert loader.functions 
        assert len(loader.functions) == 2, loader.functions # expected blah() and stop()
        for funcno, (fileno,lineno,name) in loader.functions.items():
            records = loader.fcalls( funcno )
            assert len(records) == 1
            record = records[0]
            
            assert record['function'] == funcno, (fileno,record)

    def test_c_calls( self ):
        x = []
        self.profiler.start()
        for i in range(200):
            x.append( i )
        self.profiler.stop()
        assert self.profiler.files
        assert self.profiler.functions
        
        loader = Loader( self.test_dir )
        assert loader.functions 
        assert len(loader.functions) == 2, loader.functions 
    
