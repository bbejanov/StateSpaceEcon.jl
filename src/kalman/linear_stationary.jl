##################################################################################
# This file is part of StateSpaceEcon.jl
# BSD 3-Clause License
# Copyright (c) 2020-2023, Bank of Canada
# All rights reserved.
##################################################################################

# This file contains a Kalman filter and smoother 
# implementation that is optimized 
# for stationary linear state space model 

# Implementation in this file follows 
# Time Series Analysis by State Space Methods, second edition,
# by J.Durbin and S.J.Koopman, 2012

# Notation in (Durbin & Koopman, 2012) is: 
#
#  yₜ   = Z αₜ + εₜ       εₜ ~ N(0, H)    
#      yₜ - vector varying length pₜ, 
#          set p = maximum(pₜ for t = 1:n)
#  αₜ₊₁ = T αₜ + R ηₜ     ηₜ ~ N(0, Q)
#      αₜ - vector fixed length m 
#   α₁ ~ N(a₁, P₁)
#
#   Yₙ - data for y -- matrix (n, p), NaN indicate missing observations
#
#   auₜ = E(αₜ | Yₜ)
#   Puₜ = Var(αₜ | Yₜ)
#   aₜ₊₁ = E(αₜ₊₁ | Yₜ)
#   Pₜ₊₁ = Var(αₜ₊₁ | Yₜ)

function dk_filter!(kf::KFilter, Y, mu, Z, T, H, Q, R, a₁, P₁)

    _Q = if R isa UniformScaling
        Q
    else
        R * Q * transpose(R)
    end

    have_mu = dot(mu, mu) > 0

    kfd = kf.kfd
    # implement the algorithm in 4.3.2 on p. 85

    K = Kₜ = kf.K

    x_pred = aₜ₊₁ = aₜ = kf.x_pred
    Px_pred = Pₜ₊₁ = Pₜ = kf.Px_pred

    x = auₜ = kf.x
    Px = Puₜ = kf.Px

    y_pred = kf.y_pred
    error_y = vₜ = kf.error_y
    Py_pred = Fₜ = kf.Py_pred


    ZP = similar(transpose(Z))
    UorL = similar(Fₜ)
    TP = similar(Pₜ)

    aₜ[:] = a₁
    BLAS.gemv!('N', 1.0, T, a₁, 0.0, aₜ)

    Pₜ[:, :] = P₁
    BLAS.gemm!('N', 'N', 1.0, T, Pₜ, 0.0, TP)
    BLAS.gemm!('N', 'T', 1.0, TP, T, 0.0, Pₜ)
    BLAS.axpy!(1.0, _Q, Pₜ)

    for t = kf.range

        # y_pred[:] = Z * aₜ
        BLAS.gemv!('N', 1.0, Z, aₜ, 0.0, y_pred)
        have_mu && BLAS.axpy!(1.0, mu, y_pred)

        # vₜ[:] = Y[t, :] - y_pred
        copyto!(vₜ, Y[t, :])
        BLAS.axpy!(-1.0, y_pred, vₜ)

        # Either:  PZᵀ[:, :] = Pₜ * transpose(Z)
        # BLAS.gemm!('N', 'T', 1.0, Pₜ, Z, 0.0, PZᵀ)
        # Or: ZP[:, :] = Z * Pₜ
        # BLAS.symm!('R', 'U', 1.0, Pₜ, Z, 0.0, ZP)
        BLAS.gemm!('N', 'N', 1.0, Z, Pₜ, 0.0, ZP)

        # Fₜ[:, :] = Z * PZᵀ + H
        # BLAS.gemm!('N', 'N', 1.0, Z, PZᵀ, 1.0, Fₜ)
        BLAS.gemm!('N', 'T', 1.0, ZP, Z, 0.0, Fₜ)
        BLAS.axpy!(1.0, H, Fₜ)

        @kfd_set! kfd t y_pred Py_pred error_y

        # Compute K = P Zᵀ / Fₜ using Cholesky factorization (faster than LU)

        # Cholesky factorization  Fₜ = Uᵀ U 
        copyto!(UorL, LowerTriangular(Fₜ))
        LAPACK.potrf!('L', UorL)
        CF = Cholesky(LowerTriangular(UorL))

        copyto!(Kₜ, transpose(ZP))
        rdiv!(Kₜ, CF)

        # auₜ[:] = aₜ + Kₜ * vₜ
        BLAS.gemv!('N', 1.0, Kₜ, vₜ, 0.0, auₜ)
        BLAS.axpy!(1.0, aₜ, auₜ)

        # Puₜ[:, :] = Pₜ - Kₜ * transpose(PZᵀ)
        # BLAS.gemm!('N', 'T', -1.0, Kₜ, PZᵀ, 1.0, Puₜ)
        BLAS.gemm!('N', 'N', -1.0, Kₜ, ZP, 0.0, Puₜ)
        BLAS.axpy!(1.0, Pₜ, Puₜ)

        @kfd_set! kfd t x_pred Px_pred K x Px

        # compute likelihood and residual-squared
        _assign_res2(kfd, t, error_y)
        _assign_loglik(kfd, t, error_y, CF)

        # aₜ₊₁ .= T * (aₜ + Kₜ * vₜ)
        # aₜ₊₁[:] = T * auₜ
        BLAS.gemv!('N', 1.0, T, auₜ, 0.0, aₜ₊₁)

        # Pₜ₊₁ .= T * Pₜ * transpose(T) * transpose(I(m) - Kₜ * Z) + _Q
        # Pₜ₊₁[:, :] = T * Puₜ * transpose(T) + _Q
        copyto!(Pₜ₊₁, _Q)
        BLAS.gemm!('N', 'N', 1.0, T, Puₜ, 0.0, TP)
        BLAS.gemm!('N', 'T', 1.0, TP, T, 1.0, Pₜ₊₁)

    end

    return
end



function dk_smoother!(kf::KFilter, Y, Z, T, H, Q, R, a₁, P₁)

    _Q = if R isa UniformScaling
        Q
    else
        R * Q * transpose(R)
    end

    kfd = kf.kfd
    # implement the algorithm in 4.3.2 on p. 85

    return
end
