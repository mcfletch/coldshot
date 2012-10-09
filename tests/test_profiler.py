from unittest import TestCase
from coldshot.coldshot import Profiler,RECORD_STRUCTURE
import numpy

def blah():
    return True

class Loader( object ):
    def __init__( self, filename, index_filename ):
        self.filename = filename 
        self.index_filename = index_filename
        self.data = numpy.memmap( filename ).view( RECORD_STRUCTURE )
        self.calls = self.data['rectype'] == 'c'
        self.returns = self.data['rectype'] == 'r'
        self.lines = self.data['rectype'] == 'l'
        self.files = {}
        self.file_names = {}
        self.functions = {}
        self.function_names = {}
        self.stack = []
        self.process_index( index_filename )
    def process_index( self, index_filename ):
        for line in open(index_filename):
            line = line.strip( '\n' )
            line = line.split()
            if line[0] == 'F':
                fileno,filename = line[1:3]
                fileno = int(fileno)
                self.files[fileno] = filename 
                self.file_names[filename] = fileno
            elif line[0] == 'f':
                fileno,lineno,name = line[1:4]
                fileno,lineno = int(fileno),int(lineno)
                self.functions[ (fileno,lineno) ] = name
                self.function_names[ name ] = (fileno,lineno)
    def fcalls( self, fileno, lineno ):
        """Return indices for all calls of given function"""
        return numpy.logical_and( self.calls, self.data['fileno'] == fileno, self.data['lineno'] == lineno )

class TestProfiler( TestCase ):
    TEST_FILE = '.test.profile'
    INDEX_FILE = TEST_FILE + '.index'
    def setUp( self ):
        self.profiler = Profiler( self.TEST_FILE )
    def load_file( self, filename ):
        return numpy.memmap( filename ).view( RECORD_STRUCTURE )
    def test_create( self ):
        pass 
    def test_start( self ):
        self.profiler.start()
        blah()
        self.profiler.stop()
        loader = Loader( self.profiler.filename, self.profiler.index_filename )
        
        assert loader.files
        assert len(loader.files) == 1, loader.files 
        
        assert loader.functions 
        assert len(loader.functions) == 1, loader.functions
        fileno,lineno = loader.functions.keys()[0]
        
        records = loader.fcalls( fileno,lineno )
        assert len(records)
        assert False, records
