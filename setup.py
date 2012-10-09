#!/usr/bin/env python
"""Installs ColdShot using distutils

Run:
    python setup.py install
to install the package from the source archive.
"""
import os,sys
try:
    from setuptools import setup,Extension
    setuptools = True
except ImportError:
    from distutils.core import setup,Extension
    setuptools = False
try:
    from Cython.Distutils import build_ext
except ImportError:
    have_cython = False
else:
    have_cython = True

extensions = [
    Extension(
        "coldshot.coldshot",
        [
            [
                os.path.join( 'coldshot','coldshot.c' ),
                os.path.join('coldshot','coldshot.pyx')
            ][bool( have_cython )]
        ],
        include = ['coldshot'],
        depends=['python.pxd']
    )
]
    
version = [
    (line.split('=')[1]).strip().strip('"').strip("'")
    for line in open(os.path.join('coldshot', '__init__.py'))
    if line.startswith( '__version__' )
][0]

if __name__ == "__main__":
    extraArguments = {
        'classifiers': [
            """License :: OSI Approved :: Python License""",
            """Programming Language :: Python""",
            """Topic :: Software Development :: Libraries :: Python Modules""",
            """Intended Audience :: Developers""",
        ],
        'keywords': 'profile,hotshot',
        'long_description' : """Updated version of the Hotshot profiler""",
        'platforms': ['Any'],
    }
    if setuptools:
        extraArguments['install_package_data'] = True
    ### Now the actual set up call
    if sys.platform == 'darwin':
        gui_commands = [
            'runsnake=runsnakerun.macshim:macshim',
            'runsnake32=runsnakerun.runsnake:main',
            'runsnakemem=runsnakerun.runsnake:meliaemain',
        ]
    else:
        gui_commands = [
            'runsnake=runsnakerun.runsnake:main',
            'runsnakemem=runsnakerun.runsnake:meliaemain',
        ]
    if have_cython:
        extraArguments['cmdclass'] = {
            'build_ext': build_ext,
        }
    setup (
        name = "ColdShot",
        version = version,
        url = "http://www.vrplumber.com/programming/runsnakerun/",
        download_url = "http://pypi.python.org/pypi/ColdShot",
        description = "Updated version of the Hotshot profiler",
        author = "Mike C. Fletcher",
        author_email = "mcfletch@vrplumber.com",
        install_requires = [
        ],
        license = "Python",
        package_dir = {
            'coldshot':'coldshot',
        },
        ext_modules= extensions,
        packages = [
            'coldshot',
        ],
        options = {
            'sdist':{
                'force_manifest':1,
                'formats':['gztar','zip'],},
        },
        zip_safe=False,
        entry_points = {
        },
        **extraArguments
    )

