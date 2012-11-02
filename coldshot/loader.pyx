"""Module providing a Numpy-based loader for coldshot profiles"""
import os, urllib, sys, mmap, logging
from . import profiler
from coldshot cimport *
from callsfile cimport *
log = logging.getLogger( __name__ )

__all__ = ("Loader",)

cdef class Row:
    """Base class for all profile-row types"""
    cdef public long calls 
    cdef public long time
    cdef public long child_time
    cdef public Loader loader 
    def __init__( self, Loader loader ):
        self.loader = loader
        self.time = 0
        self.calls = 0
        self.child_time = 0
    @property 
    def local( self ):
        if self.time >= self.child_time:
            return (self.time - self.child_time) * self.loader.timer_unit
        else:
            return 0.0
    @property 
    def empty( self ):
        """Calculate local time as a fraction of total time"""
        if self.time >= self.child_time:
            return (self.time - self.child_time)/float( self.time )
        return 0.0
    @property 
    def cumulative( self ):
        """Cumulative time in seconds"""
        return self.time * self.loader.timer_unit
    @property 
    def localPer( self ):
        """Average local time in seconds per call"""
        return self.local / ( self.calls or 1 )
    @property 
    def cumulativePer( self ):
        """Average cumulative time in seconds per call"""
        return self.cumulative / (self.calls or 1 )

        
cdef class CallInfo:
    """Tracks information related to a single Stack Frame
    
    if loader.individual_calls is True, then we will save these objects 
    so that the CallInfo records are available
    
    Otherwise is just used by the stack to track calls during initial loading.
    """
    cdef FunctionInfo function 
    cdef uint16_t thread
    cdef uint32_t start 
    cdef uint32_t stop
    cdef long start_index
    cdef long stop_index
    
    cdef uint16_t last_line 
    cdef uint32_t last_line_time
    def __init__( self, FunctionInfo function, uint32_t start, long start_index, uint16_t thread ):
        self.function = function 
        self.thread = thread
        self.start = start 
        self.last_line = function.line
        self.last_line_time = start 
        self.start_index = start_index
        self.stop_index = start_index
    cdef public uint32_t record_stop( self, uint32_t stop, long stop_index ):
        cdef uint32_t delta = stop - self.start 
        self.stop = stop
        self.stop_index = stop_index
        self.function.record_call(self.start)
        self.function.record_time_spent( delta )
        return delta
    cdef public uint32_t record_stop_child( self, uint32_t delta, uint32_t child ):
        """Child has exited, record time spent in the child"""
        self.function.record_time_spent_child( child, delta )
    cdef record_line( self, uint16_t new_line, uint32_t stop, int exit ):
        """Record time spent on a given line"""
        cdef FunctionLineInfo current = self.function.line_map.get( self.last_line, None )
        cdef uint32_t delta = stop-self.last_line_time
        if current is None:
            self.function.line_map[self.last_line] = current = FunctionLineInfo( self.last_line )
        current.add_time( delta, exit )
        self.last_line = new_line 
        self.last_line_time = stop 
        return 
    @property
    def cumulative( self ):
        return (self.stop - self.start) * self.function.loader.timer_unit
    @property 
    def filename( self ):
        return self.function.filename
    @property 
    def lineno( self ):
        return self.function.lineno 
    @property 
    def local( self ):
        # TODO: needs cache
        cdef uint32_t result = 0
        cdef CallInfo child 
        cdef uint32_t last_ts = self.start
        for child in self.children:
            result += child.start - last_ts 
            last_ts = child.stop 
        result += self.stop - last_ts 
        return result * self.function.loader.timer_unit
    @property 
    def empty( self ):
        return self.local / self.cumulative
    @property 
    def children( self ):
        """Children of a particular call 
        
        Return sequence of CallInfo records where:
        
            call_info.function.key in self.function.child_map.keys
            call_info.thread == self.thread 
            call_info.start_index > self.start_index 
            call_info.stop_index < self.stop_index 
        
        However, that does not take into account recursive calls to the same 
        function, so we need to prune out such that we have no *overlapping* 
        calls, that is, once we have the first (lowest) call, we need to remove 
        anything that is within that call which falls within our set, and do 
        that for each of the top-level calls found...
        """
        # TODO: needs cache
        cdef FunctionInfo other_func
        cdef CallInfo call_info
        cdef list possible
        
        possible = []
        for other in self.function.child_map.keys():
            other_func = self.function.loader.functions[other]
            for call_info in other_func.individual_calls:
                if call_info.thread == self.thread:
                    if call_info.start_index > self.start_index and call_info.stop_index < self.stop_index:
                        possible.append( (call_info.start_index,call_info) )
        return self._remove_overlaps( possible )
    
    cdef list _remove_overlaps( self, list possible ):
        """Remove the overlaps from the list of possible values for children"""
        cdef list result
        cdef CallInfo next, first
        
        if possible:
            possible.sort( )
            first = possible[0][1]
            result = [ first ]
            for index,next in possible[1:]:
                if next.stop_index < first.stop_index:
                    continue 
                else:
                    result.append( next )
                    first = next 
        else:
            result = possible
        return result
    
    def __repr__( self ):
        return '<%s records[%s:%s] duration=%ss>'%(
            self.function.name,
            self.start_index, self.stop_index,
            self.cumulative,
        )

cdef public class FunctionLineInfo [object Coldshot_FunctionLineInfo, type Coldshot_FunctionLineInfo_Type]:
    """Timing of a single line within a function"""
    cdef public uint16_t line 
    cdef public uint32_t time 
    cdef public uint32_t calls
    def __cinit__( self, uint16_t line ):
        self.line = line 
        self.time = 0
        self.calls = 0
    cdef add_time( self, uint32_t delta, int exit ):
        self.time += delta 
        if not exit:
            self.calls += 1
    def __repr__( self ):
        return b'Line %s: %s %.4fs'%( self.line, self.calls, self.time, )
    
cdef public class FileInfo [object Coldshot_FileInfo, type Coldshot_FileInfo_Type]:
    """Referenced by functions which declare the same file
    
    All built-in functions currently declare the same file number (0), so all 
    built-ins will appear to come from a single file.
    """
    cdef public object filename 
    cdef public object directory
    cdef public object path 
    cdef uint16_t fileno 
    def __init__( self, path, fileno ):
        self.path = path
        self.directory, self.filename = os.path.split( path )
        self.fileno = fileno 
    def __unicode__( self ):
        return '<%s for %s>'%( self.__class__.__name__, self.filename )
    __repr__ = __unicode__

cdef class FunctionInfo(Row):
    """Represents call/trace information for a single function
    
    Attributes of note:
    
        key -- ID/Key used in the trace to identify this function
        module -- name of the module and class (x.y.z)
        name -- name of the function/method
        file -- FileInfo for the module, note: builtins all use the same FileInfo
        line -- line on which the function begins 
        loader -- reference to the loader which created us...
        
        calls -- count of calls on the function 
        time -- cumulative time spent in the function
        child_time -- cumulative time spent in children
        line_map -- line: FunctionLineInfo mapping for each line executed
        child_map -- child_id: cumulative-time for each called child...
        
        first_timestamp -- timestamp of the first call to the function
        last_timestamp -- timestamp of the last call to the function
    
    All times/timestamps are stored in the original profiler units.
    """
    cdef public uint32_t key
    cdef public str module 
    cdef public str name 
    cdef public FileInfo file
    cdef public uint16_t line
    
    cdef public long first_timestamp
    cdef public long last_timestamp
    
    cdef public dict line_map 
    cdef public dict child_map
    cdef public list individual_calls
    
    def __init__( self, uint32_t key, str module, str name, FileInfo file, uint16_t line, object loader ):
        """Initialize the FunctionInfo instance"""
        Row.__init__( self, loader )
        self.key = key
        self.module = module 
        self.name = name 
        self.file = file
        self.line = line
        
        self.line_map = {}
        self.child_map = {}
        self.individual_calls = []
        
        self.first_timestamp = 0
        self.last_timestamp = 0
    # external data-API showing seconds 
    @property 
    def lineno( self ):
        return self.line 
    @property 
    def filename( self ):
        return self.file.filename 
    @property 
    def directory( self ):
        return self.file.directory 
    @property 
    def path( self ):
        return self.file.path
    @property
    def parents( self ):
        """Retrieve those functions which directly call me"""
        return self.loader.parents_of(self)
    @property
    def sorted_children( self ):
        """Retrieve our children records from our loader in time-sorted order
        
        returns [(cumtime,otherfunc), ... ] for all of our called children
        """
        children = [(v,self.loader.functions.get(k)) for (k,v) in self.child_map.items() if k != self.key]
        children.sort()
        return children
    @property 
    def children( self ):
        return [x[1] for x in self.sorted_children]
    def child_cumulative_time( self, other ):
        """Return cumulative time spent in other as a fraction of our cumulative time"""
        return self.child_map.get(other.key, 0)/float( self.time or 1 )
        
    # Internal APIs for Loader
    cdef record_call( self, uint32_t timestamp ):
        """Increment our internal call counter and first/last timestamp"""
        self.calls += 1
        if not self.first_timestamp:
            self.first_timestamp = timestamp
        self.last_timestamp = timestamp
    cdef record_time_spent( self, uint32_t delta ):
        """Record total time spent in the function (cumtime)"""
        self.time += delta 
    cdef record_time_spent_child( self, uint32_t child, uint32_t delta ):
        """Record time spent in a given child function"""
        cdef long current
        if child != self.key:
            # we don't consider time in ourselves to be a child...
            self.child_time += delta 
        current = self.child_map.get( child, 0 )
        self.child_map[child] = current + delta
    
    def __repr__( self ):
        return '<%s %s:%s %s:%ss>'%(
            self.__class__.__name__,
            self.module,
            self.name,
            self.calls,
            self.cumulative,
        )

cdef class ThreadStack:
    cdef uint16_t thread 
    cdef list function_stack # list of CallInfo instances 
    cdef long context_switches
    cdef uint32_t start 
    cdef uint32_t stop
    cdef Loader loader
    cdef uint16_t individual_calls
    def __cinit__( self, uint16_t thread, FunctionInfo root, uint32_t timestamp, Loader loader ):
        self.thread = thread
        self.context_switches = 0
        self.loader = loader
        self.function_stack = []
        self.start = timestamp 
        self.stop = timestamp
        self.push( root, timestamp, -1 )
    
    @property 
    def cumulative( self ):
        """Return thread duration in seconds"""
        return (self.stop - self.start)*self.loader.timer_unit
    
    cdef record_context_switch( self, timestamp ):
        self.context_switches += 1
    cdef push( self, FunctionInfo function_info, uint32_t timestamp, long index ):
        """Push a new record onto the function stack"""
        call_info = CallInfo( function_info, timestamp, index, self.thread )
        self.function_stack.append( call_info )
        if function_info.key in function_info.loader.individual_calls:
            self.individual_calls += 1
        if self.individual_calls:
            function_info.individual_calls.append( call_info )
    cdef pop( self, uint32_t timestamp, long index ):
        """Pop a single record from the stack at given timestamp"""
        cdef CallInfo call_info 
        cdef uint32_t current_function 
        
        call_info = <CallInfo>(self.function_stack[-1])
        call_info.record_line( call_info.function.line, timestamp, 0 )
        current_function = call_info.function.key 
        child_delta = call_info.record_stop( timestamp, index )
        self.stop = timestamp

        if current_function in call_info.function.loader.individual_calls:
            self.individual_calls -= 1
        
        del self.function_stack[-1]
        if self.function_stack:
            call_info = self.function_stack[-1]
            # child is current_function...
            call_info.record_stop_child( child_delta, current_function )
    
def byteswap_16( input ):
    return swap_16( input )
def byteswap_32( input ):
    return swap_32( input )
        
cdef uint16_t swap_16( uint16_t input ):
    """Byte-swap a 16-bit integer"""
    cdef uint16_t output 
    cdef uint16_t low_mask = 0x00ff 
    cdef uint16_t high_mask = 0xff00
    cdef uint16_t shift = 8
    output = ((input & low_mask) << shift) | ((input & high_mask) >> shift)
    return output
cdef uint32_t swap_32( uint32_t input ):
    """Byte-swap a 32-bit integer"""
    cdef uint32_t output 
    cdef uint32_t low_mask = 0x000000ff 
    cdef uint32_t low_mid_mask = 0x0000ff00
    cdef uint32_t high_mid_mask = 0x00ff0000
    cdef uint32_t high_mask = 0xff000000
    cdef uint32_t small_shift = 8
    cdef uint32_t big_shift = 24
    output = (
        (input & low_mask) << big_shift |
        (input & low_mid_mask) << small_shift | 
        (input & high_mid_mask) >> small_shift |
        (input & high_mask ) >> big_shift
    )
    return output

cdef public class Loader [object Coldshot_Loader, type Coldshot_Loader_Type ]:
    """Loader for Coldshot profiles
    
    Attributes of note:
    
        files -- map ID: FileInfo objects 
        file_names -- map filename: ID 
        functions -- map ID: FunctionInfo objects 
        function_names -- map function-name: ID
    """
    cdef public object directory
    
    cdef public object index_filename
    cdef public list call_files 
    cdef public list line_files 
    
    cdef public bint bigendian
    cdef public bint swapendian
    cdef public int version 
    cdef public double timer_unit
    
    cdef public dict files
    cdef public dict file_names
    cdef public dict functions 
    cdef public dict function_names
    cdef public dict threads
    
    # function IDs for which individual call records should be retained...
    cdef public set individual_calls
    
    cdef public FunctionInfo root
    
    def __cinit__( self, directory, individual_calls=None ):
        self.directory = directory
        self.index_filename = os.path.join( directory, profiler.Profiler.INDEX_FILENAME )
        self.individual_calls = individual_calls or set()
        
        self.call_files = []
        self.line_files = []
        self.files = {}
        self.file_names = {}
        self.functions = {}
        self.function_names = {}
        self.threads = {}
        self.file_names['__builtin__'] = self.files[0] = FileInfo( '__builtin__', 0 )
        self.bigendian = False 
        self.swapendian = False
        self.version = 1
        self.timer_unit = .000001
        self.root = FunctionInfo( 
            0xffffffff, '*', '*',
            self.files[0],
            0,
            self
        )
        self.functions[ self.root.key ] = self.root 
        self.function_names[ (self.root.module, self.root.name) ] = self.root

    def load( self ):
        """Scan our data-files for basic index information"""
        self.process_index( self.index_filename )
        self.process_calls( )
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
                        self.bigendian = value == 'True'
                        if self.bigendian != (sys.byteorder == 'big'):
                            self.swapendian = True
                    elif key == 'version':
                        self.version = int(value)
                    elif key == 'timer_unit':
                        self.timer_unit = float( value )
            elif line[0] == 'F':
                # code-file declaration
                fileno,filename = line[1:3]
                fileno = int(fileno)
                filename = self.unquote( filename )
                self.file_names[filename] = self.files[fileno] = FileInfo( filename, fileno )
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
                self.function_names[ (module,name) ] = self.functions[ funcno ] = FunctionInfo( 
                    funcno,module,name,
                    self.files[fileno],
                    lineno,
                    self
                )
            elif line[0] == 'D':
                # data-file declaration...
                if line[1] == 'calls':
                    self.call_files.append( line[2] )
                else:
                    log.error( "Unrecognized data-file type: %s %s", line[1], line[2] )
        self.individual_calls = self.convert_individual_calls()
    def convert_individual_calls( self ):
        # Now need to convert anything which is name-based into ID-based references 
        result = set()
        for key in self.individual_calls:
            if isinstance( key, tuple):
                function = self.function_names.get( key )
                if function is not None:
                    result.add( function.key )
                else:
                    log.warn( 'No function with key %s found', key )
            else:
                # query by ID, likely from a GUI with such access...
                result.add( key )
        return result 
    cdef uint16_t swap_16( self, uint16_t input ):
        if self.swapendian:
            return swap_16( input )
        return input 
    cdef uint32_t swap_32( self, uint32_t input ):
        if self.swapendian:
            return swap_32( input )
        return input
    cdef uint32_t extract_function( self, uint32_t input ):
        cdef uint32_t function_mask = 0x00ffffff
        return input & function_mask
    cdef uint32_t extract_flags( self, uint32_t input ):
        cdef uint32_t flag_mask = 0xff000000
        cdef uint32_t flag_shift = 24
        return (input & flag_mask) >> flag_shift
    
    def process_calls( self ):
        """Process all of our call files"""
        for call_file in self.call_files:
            self.process_call_file( call_file )
    def process_call_file( self, calls_filename ):
        """Process a CallsFile to extract basic cProfile-like information
        
        Fills in the FunctionInfo members in self.functions with the 
        basic metadata from doing a linear scan of all calls in the calls file
        
        The index *must* have been loaded or we will raise KeyError when we 
        attempt to find our FunctionInfo records
        """
        # State-lookup speedups.
        cdef uint16_t current_thread = 0# whether we need to load new thread info
        cdef uint32_t current_function = 0 # the function currently being processed...
        cdef ThreadStack stack # current stack (thread)
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
        
        # The source data...
        cdef CallsFile calls_data = CallsFile( calls_filename )
        
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
                    stacks[thread] = stack = ThreadStack( thread, self.root, timestamp, self )
                else:
                    stack.record_context_switch(timestamp)
                current_thread = thread
            
            if flags == 1: # call...
                stack.push( self.functions[function], timestamp, i )
            elif flags == 2: # return 
                # TODO: suppress start-of-func lines, as they are not really 
                # telling us anything about the individual lines...
                stack.pop( timestamp, i )
            elif flags == 0: # line...
                # we know current function exists, but there's no guarantee that the function 
                # was called within the profile operation (it is know that there will be times 
                # it was not, in fact), so we need to pull a line-specific stack for this...
                call_info = stack.function_stack[-1]
                call_info.record_line( line, timestamp, 0 )
                # TODO this is *very* wrong, as the line event can jump around files with 
                # imports and the like...
        # root needs to finalize...
        self.root.last_timestamp = highest_ts
        self.root.first_timestamp = lowest_ts 
        self.root.record_call( highest_ts )
        self.root.record_time_spent( highest_ts - lowest_ts )
        
        self.threads.update( stacks )
        calls_data.close()
#    
#    def call_tree( self, long index ):
#        """Yield all of the calls for the given function"""
#        cdef CallsFile calls_data = CallsFile( calls_filename )
#        cdef uint32_t record_function
#        cdef list result = []
#        for i in range( index, calls_data.record_count ):
#            record_function = self.extract_function( self.swap_32( calls_data.records[i].function ))
#            if record_function == function:
#                result.append( i )
#        return result

    def parents_of( self, FunctionInfo child ):
        """Retrieve those functions who are parents of functioninfo"""
        cdef FunctionInfo possible 
        result = []
        for possible in self.functions.itervalues():
            if child.key in possible.child_map:
                result.append( possible )
        return result 
    def rows( self ):
        """Produce the set of all rows"""
        return self.functions.values()
    
    def individual_root( self ):
        """Create a root for all of our individually-tracked call roots..."""
        # TODO: cache
        roots = []
        for key in self.individual_calls:
            root = self.functions.get( key )
            if root is not None:
                roots.append( root )
        return IndividualRoot( roots, self )
    def individual_rows( self ):
        """Get all individual call records"""
        cdef FunctionInfo function
        cdef list result = []
        for function in self.functions.itervalues():
            if function.individual_calls:
                result.extend( function.individual_calls )
        return result
    
class IndividualRoot:
    """Used to glue together otherwise un-related root objects"""
    def __init__( self, roots, loader ):
        """Create a root that spans a set of roots"""
        self.cumulative = sum([r.cumulative for r in roots])
        self.local = 0.0
        self.empty = 0.0
        self.localPer = 0.0
        self.calls = 1
        self.cumulativePer = self.cumulative
        self.children = sorted( roots, key=lambda x: x.cumulative )
        self.parents = []
        self.lineno = 0
        self.filename = '*'
        self.name = '*'
        self.path = '*'
        self.loader = loader 

cdef class Group(Row):
    """Group of N profile-viewable things that are lumped together"""
    cdef public str name 
    cdef public list children 
    def __init__( self, name, children, Loader loader ):
        Row.__init__( self, loader )
        self.name = name 
        self.children = children or []
        for child in self.children:
            self.add_child( child )
    cdef Row add_child( self, Row child ):
        self.children.append( child )
        return child 
        
cdef class CallGroup(Group):
    """Set of calls which are grouped together
    
    When we get to N individual calls, we lump the calls together such that 
    we see the calls as one object, with the metadata for the calls no longer 
    recorded by children (i.e. we track functions, as in a regular load).
    Each child of the CallGroup is a series of FunctionInfo records which are 
    *specific* to the calls within the call group.
    
    We record all of the individual calls *at this level* so that we can let 
    the user query for more limited data-sets, but we suppress individual calls 
    below this level...
    
    Could do it based on time too?
    """
