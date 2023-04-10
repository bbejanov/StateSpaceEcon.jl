##################################################################################
# This file is part of StateSpaceEcon.jl
# BSD 3-Clause License
# Copyright (c) 2020-2023, Bank of Canada
# All rights reserved.
##################################################################################


### API

# selected sparse linear algebra library is a Symbol
const sf_libs = (
    :default,   # use Julia's standard library (UMFPACK)
    :umfpack,   # same as :default
    :pardiso,   # use Pardiso - the one included with MKL
)

global sf_default = :umfpack

# a function to initialize a Factorization instance
# this is also a good place to do the symbolic analysis
sf_prepare(A::SparseMatrixCSC, sparse_lib::Symbol=:default) = sf_prepare(Val(sparse_lib), A)
sf_prepare(::Val{S}, args...) where {S} = throw(ArgumentError("Unknown sparse library $S. Try one of $(sf_libs)."))

# a function to calculate the numerical factors
sf_factor!(f::Factorization, A::SparseMatrixCSC) = throw(ArgumentError("Unknown factorization type $(typeof(f))."))

# a function to solve the linear system
sf_solve!(f::Factorization, x::AbstractArray) = throw(ArgumentError("Unknown factorization type $(typeof(f))."))


###########################################################################
###  Default (UMFPACK)
sf_prepare(::Val{:default}, A::SparseMatrixCSC) = sf_prepare(Val(sf_default), A)

function _sf_same_sparse_pattern(A::SparseMatrixCSC, B::SparseMatrixCSC)
    return (A.m == B.m) && (A.n == B.n) && (A.colptr == B.colptr) && (A.rowval == B.rowval)
end

mutable struct LUFactorization{Tv<:Real} <: Factorization{Tv}
    F::SuiteSparse.UMFPACK.UmfpackLU{Tv,Int}
    A::SparseMatrixCSC{Tv,Int}
end

@timeit_debug timer "sf_prepare_lu" function sf_prepare(::Val{:umfpack}, A::SparseMatrixCSC)
    Tv = eltype(A)
    @timeit_debug timer "_lu_full" F = lu(A)
    return LUFactorization{Tv}(F, A)
end

@timeit_debug timer "sf_factor!_lu" function sf_factor!(f::LUFactorization, A::SparseMatrixCSC)
    _A = f.A
    if _sf_same_sparse_pattern(A, _A)
        if A.nzval ≈ _A.nzval
            # matrix hasn't changed significantly
            nothing
        else
            # sparse pattern is the same, different numbers
            f.A = A
            @timeit_debug timer "_lu_num" lu!(f.F, A)
        end
    else
        # totally new matrix, start over
        f.A = A
        @timeit_debug timer "_lu_full" f.F = lu(A)
    end
    return f
end

@timeit_debug timer "sf_solve!_lu" sf_solve!(f::LUFactorization, x::AbstractArray) = (ldiv!(f.F, x); x)

###########################################################################
###  Pardiso (thanks to @KristofferC)

# See https://github.com/JuliaSparse/Pardiso.jl/blob/master/examples/exampleunsym.jl
# See https://www.intel.com/content/www/us/en/develop/documentation/onemkl-developer-reference-c/top/sparse-solver-routines/onemkl-pardiso-parallel-direct-sparse-solver-iface/pardiso-iparm-parameter.html

mutable struct PardisoFactorization{Tv<:Real} <: Factorization{Tv}
    ps::MKLPardisoSolver
    A::SparseMatrixCSC{Tv,Int}
end

@timeit_debug timer "sf_prepare_par" function sf_prepare(::Val{:pardiso}, A::SparseMatrixCSC)
    Tv = eltype(A)
    ps = MKLPardisoSolver()
    set_matrixtype!(ps, Pardiso.REAL_NONSYM)
    pardisoinit(ps)
    fix_iparm!(ps, :N)
    # set_iparm!(ps, 1, 1) # Override defaults
    # set_iparm!(ps, 2, 2) # Select algorithm
    pf = PardisoFactorization{Tv}(ps, get_matrix(ps, A, :N))
    finalizer(pf) do x
        set_phase!(x.ps, Pardiso.RELEASE_ALL)
        pardiso(x.ps)
    end
    _pardiso_full!(pf)
    return pf
end

@timeit_debug timer "_pardso_full" function _pardiso_full!(pf::PardisoFactorization)
    # run the analysis phase
    ps = pf.ps
    set_phase!(ps, Pardiso.ANALYSIS_NUM_FACT)
    pardiso(ps, pf.A, Float64[])
    return pf
end

@timeit_debug timer "_pardso_num" function _pardiso_numeric!(pf::PardisoFactorization)
    # run the analysis phase
    ps = pf.ps
    set_phase!(ps, Pardiso.NUM_FACT)
    pardiso(ps, pf.A, Float64[])
    return pf
end

@timeit_debug timer "sf_factor!_par" function sf_factor!(pf::PardisoFactorization, A::SparseMatrixCSC)
    A = get_matrix(pf.ps, A, :N)::typeof(A)
    _A = pf.A
    if _sf_same_sparse_pattern(A, _A)
        if A.nzval ≈ _A.nzval
            # same matrix, factorization hasn't changed
            nothing
        else
            # same sparsity pattern, but different numbers
            pf.A = A
            _pardiso_numeric!(pf)
        end
    else
        # totally new matrix, start over
        pf.A = A
        _pardiso_full!(pf)
    end
    return pf
end

@timeit_debug timer "sf_solve!_par" function sf_solve!(pf::PardisoFactorization, x::AbstractArray)
    ps = pf.ps
    set_phase!(ps, Pardiso.SOLVE_ITERATIVE_REFINE)
    pardiso(ps, x, pf.A, copy(x))
    return x
end

