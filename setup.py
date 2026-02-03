# setup.py
from setuptools import setup, Extension
from Cython.Build import cythonize
import numpy

extensions = [
    # 舊的 Beam Search Solver
    Extension(
        "bs_solver",
        sources=["bs_solver.pyx"],
        language="c++",
        extra_compile_args=["-std=c++11", "-O3"],
    ),
    Extension(
        "rb_solver",
        sources=["rb_solver.pyx"],
        language="c++",
        extra_compile_args=["-std=c++11", "-O3"],
    )
]

setup(
    name="BRP_Solvers",
    ext_modules=cythonize(extensions, language_level="3"),
    include_dirs=[numpy.get_include()]
)