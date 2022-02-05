using Oceananigans
using CUDA
using Glob
using Test

include("utils_for_runtests.jl")

archs = test_architectures()

#####
##### Checkpointer tests
#####

function test_model_equality(test_model, true_model)
    CUDA.@allowscalar begin
        for q in keys(test_model.velocities)
            @test parent(test_model.velocities[q]) ≈ parent(true_model.velocities[q])
        end

        for c in keys(test_model.tracers)
            @test parent(test_model.tracers[c]) ≈ parent(true_model.tracers[c])
        end

        for q in keys(test_model.timestepper.Gⁿ)
            @test parent(test_model.timestepper.Gⁿ[c]) ≈ parent(true_model.timestepper.Gⁿ[c])
            @test parent(test_model.timestepper.G⁻[c]) ≈ parent(true_model.timestepper.G⁻[c])
        end
    end
    return nothing
end

"""
Run two coarse rising thermal bubble simulations and make sure

1. When restarting from a checkpoint, the restarted model matches the non-restarted
   model to machine precision.

2. When using set!(test_model) to a checkpoint, the new model matches the non-restarted
   simulation to machine precision.

3. run!(test_model, pickup) works as expected
"""
function test_thermal_bubble_checkpointer_output(arch)
    #####
    ##### Create and run "true model"
    #####

    Nx, Ny, Nz = 16, 16, 16
    Lx, Ly, Lz = 100, 100, 100
    Δt = 6

    grid = RectilinearGrid(arch, size=(Nx, Ny, Nz), extent=(Lx, Ly, Lz))
    closure = IsotropicDiffusivity(ν=4e-2, κ=4e-2)
    true_model = NonhydrostaticModel(grid=grid, closure=closure,
                                     buoyancy=SeawaterBuoyancy(), tracers=(:T, :S))

    test_model = deepcopy(true_model)

    # Add a cube-shaped warm temperature anomaly that takes up the middle 50%
    # of the domain volume.
    i1, i2 = round(Int, Nx/4), round(Int, 3Nx/4)
    j1, j2 = round(Int, Ny/4), round(Int, 3Ny/4)
    k1, k2 = round(Int, Nz/4), round(Int, 3Nz/4)
    CUDA.@allowscalar true_model.tracers.T.data[i1:i2, j1:j2, k1:k2] .+= 0.01

    return run_checkpointer_tests(true_model, test_model, Δt)
end

function test_hydrostatic_splash_checkpointer(arch, free_surface)
    #####
    ##### Create and run "true model"
    #####

    Nx, Ny, Nz = 16, 16, 4
    Lx, Ly, Lz = 1, 1, 1

    grid = RectilinearGrid(arch, size=(Nx, Ny, Nz), x=(-10, 10), y=(-10, 10), z=(-1, 0))
    closure = IsotropicDiffusivity(ν=1e-2, κ=1e-2)
    true_model = HydrostaticFreeSurfaceModel(; grid, free_surface, closure, buoyancy=nothing, tracers=())
    test_model = deepcopy(true_model)

    ηᵢ(x, y) = 1e-3 * exp(-x^2 - y^2)
    set!(true_model, η=ηᵢ)

    return run_checkpointer_tests(true_model, test_model, 1e-6)
end

function run_checkpointer_tests(true_model, test_model, Δt)

    true_simulation = Simulation(true_model, Δt=Δt, stop_iteration=5)

    checkpointer = Checkpointer(true_model, schedule=IterationInterval(5), force=true)
    push!(true_simulation.output_writers, checkpointer)

    run!(true_simulation) # for 5 iterations

    checkpointed_model = deepcopy(true_simulation.model)

    true_simulation.stop_iteration = 9
    run!(true_simulation) # for 4 more iterations

    #####
    ##### Test `set!(model, checkpoint_file)`
    #####

    set!(test_model, "checkpoint_iteration5.jld2")

    @test test_model.clock.iteration == checkpointed_model.clock.iteration
    @test test_model.clock.time == checkpointed_model.clock.time
    test_model_equality(test_model, checkpointed_model)

    # This only applies to QuasiAdamsBashforthTimeStepper:
    @test test_model.timestepper.previous_Δt == checkpointed_model.timestepper.previous_Δt

    #####
    ##### Test pickup from explicit checkpoint path
    #####

    test_simulation = Simulation(test_model, Δt=Δt, stop_iteration=9)

    # Pickup from explicit checkpoint path
    run!(test_simulation, pickup="checkpoint_iteration0.jld2")

    @info "Testing model equality when running with pickup=checkpoint_iteration0.jld2."
    @test test_simulation.model.clock.iteration == true_simulation.model.clock.iteration
    @test test_simulation.model.clock.time == true_simulation.model.clock.time
    test_model_equality(test_model, true_model)

    run!(test_simulation, pickup="checkpoint_iteration5.jld2")
    @info "Testing model equality when running with pickup=checkpoint_iteration5.jld2."

    @test test_simulation.model.clock.iteration == true_simulation.model.clock.iteration
    @test test_simulation.model.clock.time == true_simulation.model.clock.time
    test_model_equality(test_model, true_model)

    #####
    ##### Test `run!(sim, pickup=true)
    #####

    # Pickup using existing checkpointer
    test_simulation.output_writers[:checkpointer] =
        Checkpointer(test_model, schedule=IterationInterval(5), force=true)

    run!(test_simulation, pickup=true)
    @info "    Testing model equality when running with pickup=true."

    @test test_simulation.model.clock.iteration == true_simulation.model.clock.iteration
    @test test_simulation.model.clock.time == true_simulation.model.clock.time
    test_model_equality(test_model, true_model)

    run!(test_simulation, pickup=0)
    @info "    Testing model equality when running with pickup=0."

    @test test_simulation.model.clock.iteration == true_simulation.model.clock.iteration
    @test test_simulation.model.clock.time == true_simulation.model.clock.time
    test_model_equality(test_model, true_model)

    run!(test_simulation, pickup=5)
    @info "    Testing model equality when running with pickup=5."

    @test test_simulation.model.clock.iteration == true_simulation.model.clock.iteration
    @test test_simulation.model.clock.time == true_simulation.model.clock.time
    test_model_equality(test_model, true_model)

    rm("checkpoint_iteration0.jld2", force=true)
    rm("checkpoint_iteration5.jld2", force=true)

    return nothing
end

function run_checkpointer_cleanup_tests(arch)
    grid = RectilinearGrid(arch, size=(1, 1, 1), extent=(1, 1, 1))
    model = NonhydrostaticModel(grid=grid,
                                buoyancy=SeawaterBuoyancy(), tracers=(:T, :S)
                                )

    simulation = Simulation(model, Δt=0.2, stop_iteration=10)

    simulation.output_writers[:checkpointer] = Checkpointer(model, schedule=IterationInterval(3), cleanup=true)
    run!(simulation)

    [@test !isfile("checkpoint_iteration$i.jld2") for i in 1:10 if i != 9]
    @test isfile("checkpoint_iteration9.jld2")

    rm("checkpoint_iteration9.jld2", force=true)

    return nothing
end

for arch in archs
    @testset "Checkpointer [$(typeof(arch))]" begin
        @info "  Testing Checkpointer [$(typeof(arch))]..."
        #test_thermal_bubble_checkpointer_output(arch)
    
        for free_surface in [ExplicitFreeSurface(gravitational_acceleration=1),
                             ImplicitFreeSurface(gravitational_acceleration=1)]

            test_hydrostatic_splash_checkpointer(arch, free_surface)
        end

        run_checkpointer_cleanup_tests(arch)
    end
end
