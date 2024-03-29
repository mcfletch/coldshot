from unittest import TestCase
from coldshot import profiler, loader 
import tempfile, os, shutil, time

def first_level():
    second_level()
    # hello
    second_level()
def second_level():
    third_level()
    third_level()
def third_level():
    time.sleep( 0.001 )

def recurse( x ):
    if x <= 1:
        return x
    else:
        return recurse( x-1 ) + recurse( x-2 )

class TestLoaderBase( TestCase ):
    first_key = ('tests.test_loader','first_level')
    second_key = ('tests.test_loader','second_level')
    third_key = ('tests.test_loader','third_level')
    recurse_key = ('tests.test_loader','recurse')
    def setUp( self ):
        self.test_dir = tempfile.mkdtemp( prefix = 'coldshot-test' )
        self.profiler = profiler.Profiler( self.test_dir )
        self.profiler.start()
        recurse(10)
        first_level()
        self.profiler.stop()
        self.loader = self.create_loader()
    def create_loader( self ):
        load = loader.Loader( self.test_dir )
        load.load()
        return load
    def tearDown( self ):
        shutil.rmtree( self.test_dir, True )
    
class TestLoader( TestLoaderBase ):
        
    def test_cumulative( self ):
        root = self.loader.info.roots['functions']
        cumulative = root.cumulative
        local = root.local
        assert cumulative, root.time
        assert local, root.local
        assert abs( cumulative - 0.004 ) < .001, ("Expect a little more accuracy from time and profiler", cumulative)
        assert local < .001, "Expect less than 1ms for calling two functions"
    
    def test_has_functions( self ):
        for key in [self.first_key, self.second_key, self.third_key]:
            assert key in self.loader.info.function_names
    
    def test_parents( self ):
        func = self.loader.info.function_names[ self.recurse_key ]
        parents = func.parents 
        assert func in parents, parents

    def test_root_children( self ):
        root = self.loader.info.function_names[ ('*','*') ]
        assert len( root.children ) == 2, root.children
    
    def test_module_rows( self ):
        self.loader.info.finalize_modules()
        rows = self.loader.info.modules
        time= rows['time']
        assert .004 < time.cumulative < .005, ("""Expect better resolution than .001""",time.cumulative)
        for row in rows.values():
            row.empty # testing accessing it...
            if row.key != '':
                assert row.parents 
            else:
                assert not row.parents
    def test_function_line_numbers( self ):
        function= self.loader.info.function_names[ self.first_key ]
        assert len(function.line_map) == 3, function.line_map
        for key,value in function.line_map.items():
            assert value.line == key, (value.line,key)

class TestLoaderIndividual( TestLoaderBase ):
    def create_loader( self ):
        load = loader.Loader( self.test_dir, individual_calls=set([  
            ('tests.test_loader','first_level') 
        ]))
        load.load()
        return load

    def test_individual_calls( self ):
        """Individual call information on functions"""
        func = self.loader.info.function_names[ self.first_key ]
        assert len(func.individual_calls) == 1, func.individual_calls
        first_level = func.individual_calls[0]
        children = first_level.children
        assert len(children) == 2, children
        for child in children:
            assert len(child.children) == 2 # second level
            assert 0.003 > child.cumulative > .002, child.cumulative # should take slightly longer than 0.002
            assert 0.001 > child.local > 0.000001, child.local # should be an extremely small slice
            for grandchild in child.children:
                assert len(grandchild.children) == 1 # third level
                assert 0.002 > grandchild.cumulative > 0.001, grandchild.cumulative
                for greatgrandchild in grandchild.children:
                    assert len(greatgrandchild.children) == 0 # time.sleep
