"""Module providing a Numpy-based loader for coldshot profiles"""
import os, numpy
from . import coldshot

class Loader( object ):
    def __init__( self, directory ):
        self.directory = directory
        self.index_filename = os.path.join( directory, coldshot.Writer.INDEX_FILENAME )
        self.calls_filename = os.path.join( directory, coldshot.Writer.CALLS_FILENAME )
        self.lines_filename = os.path.join( directory, coldshot.Writer.LINES_FILENAME )
        
        self.calls_data = numpy.memmap( self.calls_filename ).view( coldshot.CALLS_STRUCTURE )
        self.lines_data = numpy.memmap( self.lines_filename ).view( coldshot.LINES_STRUCTURE )
        
        self.calls = self.calls_data['rectype'] == 'c'
        self.returns = self.calls_data['rectype'] == 'r'
        
        self.files = {}
        self.file_names = {}
        self.functions = {}
        self.function_names = {}
        self.stack = []
        self.process_index( self.index_filename )
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
                funcno,fileno,lineno,name = line[1:5]
                funcno,fileno,lineno = int(funcno),int(fileno),int(lineno)
                self.functions[ funcno ] = (fileno,lineno,name)
                self.function_names[ name ] = funcno
    def fcalls( self, funcno ):
        """Return indices for all calls of given function"""
        return self.calls_data[numpy.logical_and( 
            self.calls, 
            self.calls_data['function'] == funcno
        )]
    
