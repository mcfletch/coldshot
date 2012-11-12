"""Module providing a loader for Coldshot profiles"""
import os, urllib, sys, mmap, logging
from . import profiler
from coldshot.coldshot cimport *
from coldshot.eventsfile cimport *
from coldshot.stack cimport *
log = logging.getLogger( __name__ )

__all__ = ("Loader",)

cdef public class Loader [object Coldshot_Loader, type Coldshot_Loader_Type ]:
    """Loader for Coldshot profiles
    
    Attributes of note:
    
        directory -- directory from which data is loaded
        
        index_filename -- filename from which the index was loaded
        
        call_files -- list of call files to load (defined in the index)
        
        info -- LoaderInfo instance populated by the loading process
    """
    cdef public object directory
    
    cdef public object index_filename
    cdef public list call_files 
    
    cdef public int version 
    
    cdef public LoaderInfo info
    
    # function IDs for which individual call records should be retained...
    cdef public set individual_calls
    
    def __cinit__( self, directory, individual_calls=None ):
        self.directory = directory
        self.index_filename = os.path.join( directory, profiler.Profiler.INDEX_FILENAME )
        
        self.individual_calls = individual_calls or set()
        self.call_files = []
        
        self.info = LoaderInfo()

    def load( self ):
        """Scan our data-files for basic index information"""
        self.process_index( self.index_filename )
        self.process_calls( )
        return self.info
    def unquote( self, name ):
        """Remove quoting to get the original name"""
        return urllib.unquote( name )
    def process_index( self, index_filename ):
        """Process the plain-text index file to load our declarations"""
        for line in open(index_filename):
            line = line.strip( '\n' )
            line = line.split()
            if line[0] == 'P':
                # prefix/metadata declaration...
                for variable in line[2:]:
                    key,value = variable.split('=')
                    if key == 'bigendian':
                        self.info.bigendian = value == 'True'
                        if self.info.bigendian != (sys.byteorder == 'big'):
                            self.info.swap_endian = True
                    elif key == 'version':
                        self.version = int(value)
                    elif key == 'timer_unit':
                        self.info.timer_unit = float( value )
            elif line[0] == 'F':
                # code-file declaration
                fileno,filename = line[1:3]
                fileno = int(fileno)
                filename = self.unquote( filename )
                self.info.add_file( filename, fileno )
            elif line[0] == 'f':
                # function/built-in declaration
                try:
                    funcno,fileno,lineno,module,name = line[1:6]
                except Exception as err:
                    err.args += (line,)
                    raise
                funcno,fileno,lineno = int(funcno),int(fileno),int(lineno)
                
                module = self.unquote( module )
                name = self.unquote( name )
                self.info.add_function( FunctionInfo( 
                    funcno,module,name,
                    self.info.files[fileno],
                    lineno,
                    self.info
                ))
            elif line[0] == 'D':
                # data-file declaration...
                if line[1] == 'calls':
                    self.call_files.append( line[2] )
                else:
                    log.error( "Unrecognized data-file type: %s %s", line[1], line[2] )
            elif line[0] == 'A':
                # annotation added...
                self.info.add_annotation( int(line[1]), self.unquote(line[2]))
        self.info.individual_calls = self.convert_individual_calls()
    def convert_individual_calls( self ):
        """Convert the individual calls mapping into id-based mapping and add to info"""
        # Now need to convert anything which is name-based into ID-based references 
        result = set()
        for key in self.individual_calls:
            if isinstance( key, tuple):
                function = self.info.function_names.get( key )
                if function is not None:
                    result.add( function.key )
                elif key == ('*','*'):
                    result.add( key )
                else:
                    log.warn( 'No function with key %s found', key )
            else:
                # query by ID, likely from a GUI with such access...
                result.add( key )
        return result 
    cdef uint16_t swap_16( self, uint16_t input ):
        """Do a 16-bit integer endian swap"""
        if self.info.swapendian:
            return swap_16( input )
        return input 
    cdef uint32_t swap_32( self, uint32_t input ):
        """Do a 32-bit integer endian swap"""
        if self.info.swapendian:
            return swap_32( input )
        return input
    cdef uint32_t extract_function( self, uint32_t input ):
        """Extract function from packed input"""
        cdef uint32_t function_mask = 0x00ffffff
        return input & function_mask
    cdef uint32_t extract_flags( self, uint32_t input ):
        """Extract flags from the packed input"""
        cdef uint32_t flag_mask = 0xff000000
        cdef uint32_t flag_shift = 24
        return (input & flag_mask) >> flag_shift
    
    def process_calls( self ):
        """Process all of our call files"""
        for call_file in self.call_files:
            self.process_call_file( call_file )
    def process_call_file( self, calls_filename ):
        """Process a EventsFile to extract basic cProfile-like information
        
        Fills in the FunctionInfo members in self.functions with the 
        basic metadata from doing a linear scan of all calls in the calls file
        
        The index *must* have been loaded or we will raise KeyError when we 
        attempt to find our FunctionInfo records
        """
        # State-lookup speedups.
        cdef uint16_t current_thread = 0# whether we need to load new thread info
        cdef uint32_t current_function = 0 # the function currently being processed...
        cdef Stack stack # current stack (thread)
        cdef FunctionInfo function_info # current function 
        cdef CallInfo call_info # temp for function being called...
        cdef CallInfo root_call
        
        cdef uint32_t function_mask = 0x00ffffff
        
        # incoming record information
        cdef uint16_t thread = 0
        cdef uint32_t function = 0
        cdef uint32_t timestamp = 0
        cdef uint32_t flags = 0
        cdef uint16_t line = 0

        # Canonical state storage...
        cdef dict stacks = {}
        cdef FunctionInfo root = self.info.roots[ 'functions' ]
        
        # The source data...
        cdef EventsFile calls_data = EventsFile( calls_filename )
        
        function_info = None
        
        current_thread = 0
        
        cdef uint32_t lowest_ts = 0xffffffff
        cdef uint32_t highest_ts = 0
        
        for i in range( calls_data.record_count ):
            thread = self.swap_16( calls_data.records[i].thread )
            timestamp = self.swap_32( calls_data.records[i].timestamp )
            line = self.swap_16( calls_data.records[i].line )
            
            function = self.swap_32( calls_data.records[i].function )
            flags = self.extract_flags( function )
            function = self.extract_function( function )
            
            if timestamp < lowest_ts:
                lowest_ts = timestamp
            if timestamp > highest_ts:
                highest_ts = timestamp
                
            if thread != current_thread:
                # we are following a thread context switch, 
                # we should *likely* track that somewhere...
                stack = stacks.get( thread )
                if stack is None:
                    stacks[thread] = stack = Stack( thread, timestamp, self.info, root )
                else:
                    stack.record_context_switch(timestamp)
                current_thread = thread
            
            if flags == 1: # call...
                stack.push( self.info.functions[function], timestamp, i )
            elif flags == 2: # return 
                # TODO: suppress start-of-func lines, as they are not really 
                # telling us anything about the individual lines...
                stack.pop( timestamp, i )
            elif flags == 0: # line...
                stack.line( line, timestamp )
            elif flags == 3: # annotation
                stack.annotation( function, timestamp, line )
        # root needs to finalize...
        root.last_timestamp = highest_ts
        root.first_timestamp = lowest_ts 
        root.record_call( highest_ts )
        root.record_time_spent( highest_ts - lowest_ts )
        
        self.info.threads.update( stacks )
        calls_data.close()
    
