using StatsBase
using Distributions

"""
Matrix factorization object
"""
type MatFac
    name::AbstractString
    L::Int64                            # Number of users
    M::Int64                            # Number of items
    D::Int64                            # Dimensionality
    N::Int64                            # Number of observations
    U::Array{ Float64, 2 }              # Latent feature vector
    V::Array{ Float64, 2 }              # Latent feature vector
    a::Array{ Float64, 1 }              # User bias terms
    b::Array{ Float64, 1 }              # Item bias terms
    train::Array{ Int64, 2 }            # Training dataset
    test::Array{ Int64, 2 }             # Test dataset
    α::Float64                          # Gamma shape hyperparameter for prior
    β::Float64                          # Gamma rate hyperparameter for prior
    Λ_U::Array{ Float64, 1 }            # Parameter for prior for U
    Λ_V::Array{ Float64, 1 }            # Parameter for prior for V
    λ_a::Float64                        # Parameter for prior for a
    λ_b::Float64                        # Parameter for prior for b
    τ::Float64                          # Precision (assumed known)
    item_counts::Dict{Int64,Int64}      # Number of items for each user
    user_counts::Dict{Int64,Int64}      # Number of users for each item
end

"""
Initialise mat_fac object from train and test set
"""
function MatFac( train, test, D = 20 )
    model_name = "MatFac"
    ( L, M ) = maximum( train[:,1:2], 1 )
    N = size( train, 1 )
    α = 1
    β = 300
    # Simulate initial values from prior
    Λ_U = 2*ones(D)
    Λ_V = 2*ones(D)    
    U = 0.35*ones( ( D, L ) )
    V = 0.35*ones( ( D, M ) )
    a = 0.05*ones( L )
    b = 0.05*ones( M )
    λ_a = 2
    λ_b = 2
    τ = 3.0
    item_counts = countmap( train[:,1] )
    user_counts = countmap( train[:,2] )
    MatFac( model_name, L, M, D, N, U, V, a, b, train, test, α, β, Λ_U, Λ_V, λ_a, λ_b, τ, item_counts, user_counts )
end

"""
Update Λ using Gibbs
"""
function update_Λ( model::MatFac )
    for d in 1:model.D
        dens_current = Gamma( model.α + model.L/2, model.β + 1/2 * sum( model.U[d,:] .^ 2 ) )
        model.Λ_U[d] = rand( dens_current )
        dens_current = Gamma( model.α + model.M/2, model.β + 1/2 * sum( model.V[d,:] .^ 2 ) )
        model.Λ_V[d] = rand( dens_current )
    end
    dens_current = Gamma( model.α + model.L/2, model.β + 1/2 * sum( model.a .^ 2 ) )
    model.λ_a = rand( dens_current )
    dens_current = Gamma( model.α + model.M/2, model.β + 1/2 * sum( model.b .^ 2 ) )
    model.λ_b = rand( dens_current )
end

"""
Calculate estimates of log density gradient at subsampled points
"""
function dlogdens( model::MatFac, subsample )
    # Initialise containers for gradients
    size_subsample = length( subsample )
    dlogU = zeros( size_subsample, model.D )
    dlogV = zeros( size_subsample, model.D )
    dloga = zeros( size_subsample )
    dlogb = zeros( size_subsample )
    # Calculate log density gradient for each element in minibatch, add to gradient containers
    for (i,index) in enumerate(subsample)
        x = model.train[index,:]
        dlogU[i,:] = dlogdensU( model, x )
        dlogV[i,:] = dlogdensV( model, x )
        dloga[i] = dlogdensa( model, x )
        dlogb[i] = dlogdensb( model, x )
    end
    return( (dlogU, dlogV, dloga, dlogb) )
end

"""
Gradient of the log density wrt U
"""
function dlogdensU( model::MatFac, x::Array{Int64,1} )
    ( user, item, rating ) = x
    dens_out = model.τ * ( rating - dot( model.U[:,user], model.V[:,item] ) -
        model.a[user] - model.b[item] )*model.V[:,item]
    return( dens_out )
end

"""
Gradient of the log density wrt V
"""
function dlogdensV( model::MatFac, x::Array{Int64,1} )
    ( user, item, rating ) = x
    dens_out = model.τ * ( rating - dot( model.U[:,user], model.V[:,item] ) - 
        model.a[user] - model.b[item] )*model.U[:,user]
    return( dens_out )
end

"""
Gradient of log density wrt user bias term a
"""
function dlogdensa( model::MatFac, x::Array{Int64,1} )
    ( user, item, rating ) = x
    dens_out = model.τ * ( rating - dot( model.U[:,user], model.V[:,item] ) - 
        model.a[user] - model.b[item] )
    return( dens_out )
end

"""
Gradient of log density wrt item bias term a
"""
function dlogdensb( model::MatFac, x::Array{Int64,1} )
    ( user, item, rating ) = x
    dens_out = model.τ * ( rating - dot( model.U[:,user], model.V[:,item] ) - 
        model.a[user] - model.b[item] )
    return( dens_out )
end

function dlogpostbackup( model::MatFac )
    # Adjust log density gradient estimate so it's unbiased
    n = size( subsample, 1 )
    dlogU *= model.N / n
    dlogV *= model.N / n
    dloga *= model.N / n
    dlogb *= model.N / n
    # Add log prior gradient estimate to containers
    minibatch = model.train[subsample,:]
    dlogpriorU( model, minibatch, dlogU, U_curr )
    dlogpriorV( model, minibatch, dlogV, V_curr )
    dlogpriora( model, minibatch, dloga, a_curr )
    dlogpriorb( model, minibatch, dlogb, b_curr )
    return ( dlogU, dlogV, dloga, dlogb )
end

"""
Gradient of the log prior wrt U
"""
function dlogpriorU(model::MatFac, minibatch::Array{Int64,2}, dlogU::Array{Float64,2})
    n = size( minibatch, 1 )
    users = unique(minibatch[:,1])
    for user in users
        h = 1 - ( 1 - model.item_counts[user] / model.N )^n
        for d in model.D
            dlogU[d,user] -= model.Λ_U[d] * model.U[d,user] / h
        end
    end
end

"""
Gradient of the log prior wrt V
"""
function dlogpriorV(model::MatFac, minibatch::Array{Int64,2}, dlogV::Array{Float64,2})
    n = size( minibatch, 1 )
    items = unique( minibatch[:,2] )
    for item in items
        h = 1 - ( 1 - model.user_counts[item] / model.N )^n
        for d in model.D
            dlogV[d,item] -= model.Λ_V[d] * model.V[d,item] / h
        end
    end
end

"""
Gradient of the log prior for user bias a
"""
function dlogpriora(model::MatFac, minibatch::Array{Int64,2}, dloga::Array{Float64,1})
    n = size( minibatch, 1 )
    users = unique( minibatch[:,1] )
    for user in users
        h = 1 - ( 1 - model.item_counts[user] / model.N )^n
        dloga[user] -= model.λ_a * model.a[user] / h
    end
end

"""
Gradient of the log prior for item bias b
"""
function dlogpriorb(model::MatFac, minibatch::Array{Int64,2}, dlogb::Array{Float64,1})
    n = size( minibatch, 1 )
    items = unique( minibatch[:,2] )
    for item in items
        h = 1 - ( 1 - model.user_counts[item] / model.N )^n
        dlogb[item] -= model.λ_b * model.b[item] / h
    end
end

"""
Calculate RMSE of test set
"""
function rmse( model::MatFac )
    rmse = 0
    test_size = size( model.test, 1 )
    for i in 1:test_size
        ( user, item, rating ) = model.test[i,:]
        try
            rmse += ( rating - dot( model.U[:,user], model.V[:,item] - 
                      model.a[user] - model.b[item] ) )^2
        catch
            continue
        end
    end
    rmse = sqrt( rmse / test_size )
    return rmse
end
