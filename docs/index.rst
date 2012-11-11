Coldshot Tracing Profiler for Python
====================================

Coldshot is a tracing profiler for use with CPython.

Command-line Usage
----------------------------

.. code:: bash

    $> coldshot --lines -o test.profile path/to/script.py argument1 argument2

Will produce a directory named ``test.profile`` into with a (potentially very large)
set of data files.  These data files are loadable  with the RunSnakeRun visualizer, or 
may be viewed with built-in basic report functionality:

.. code:: bash 

    $> coldshot-report test.profile

Profiling a Single Function
----------------------------------

.. code:: python

    from coldshot.decorator import profile
    
    @profile( 'test.profile', lines=True )
    def long_running_process():
        """Your long running code"""
    
Loading Profiles Programatically 
-------------------------------------------

.. code:: python

    from coldshot import loader 
    
    info = loader.Loader( 'test.profile' ).load()
    
    for function in info.funtions.values():
        print function.module,function.name, function.cumulative

        
Contents:
 
.. toctree::
   :maxdepth: 2

   coldshot.profiler
   coldshot.loader
   coldshot.stack

Indices and tables
==================

* :ref:`genindex`
* :ref:`modindex`
* :ref:`search`

