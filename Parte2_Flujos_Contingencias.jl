using PowerSystems, PowerFlows
using CSV, DataFrames, Dates

println("=== Iniciando Configuración Base para Flujos de Potencia ===")

# 1. Carga inicial del sistema y modificación topológica
file_path_static = joinpath(@__DIR__, "IEEE_14_Bus_Proyecto.m")
sys = System(file_path_static)
S_base = get_base_power(sys)

# Ponderación de demanda 
λ_load = 1.10
cargas = collect(get_components(PowerLoad, sys))
base_loads = [(load, get_active_power(load), get_reactive_power(load)) for load in cargas]

for (load, p_base, q_base) in base_loads
    set_active_power!(load, p_base * λ_load)
    set_reactive_power!(load, q_base * λ_load)
end

# Reemplazo por planta solar 
gen_termico_a_retirar = get_component(ThermalStandard, sys, "gen-3") 
bus_solar = get_bus(gen_termico_a_retirar)
remove_component!(sys, gen_termico_a_retirar)
set_bustype!(bus_solar, ACBusTypes.PQ)

gen_solar = RenewableDispatch(
    name="gen-solar", available=true, bus=bus_solar,
    active_power=0.0, reactive_power=0.0, rating=1.0, 
    prime_mover_type=PrimeMovers.PVe,
    reactive_power_limits=(min=0.0, max=0.0), power_factor=1.0,
    operation_cost=TwoPartCost(VariableCost(0.0), 0.0), base_power=S_base)
add_component!(sys, gen_solar)

# 2. Carga de Datos y Resultados del Archivo 1
ruta_perfiles = joinpath(@__DIR__, "perfiles_normalizados.csv")
df_perfiles = CSV.read(ruta_perfiles, DataFrame)

# CORRECCIÓN DE RUTA: Ahora busca en la carpeta 1.1.caso_base
ruta_despacho = joinpath(@__DIR__, "1.1.caso_base", "1_despacho_resultados.csv")
if !isfile(ruta_despacho)
    error("No se encontró '1_despacho_resultados.csv' en la carpeta '1.1.caso_base'. Ejecuta Parte1_ED.jl primero.")
end
despacho_p_print = CSV.read(ruta_despacho, DataFrame)

# 3. Preparación de Escenarios
sys_base = deepcopy(sys)
sys_cont_a = deepcopy(sys)
sys_cont_b = deepcopy(sys)

timestamps = despacho_p_print.DateTime
n_buses = length(get_components(Bus, sys))

df_voltajes_base = DataFrame(DateTime = timestamps)
df_voltajes_cont_a = DataFrame(DateTime = timestamps)
df_voltajes_cont_b = DataFrame(DateTime = timestamps)

for b in 1:n_buses
    df_voltajes_base[!, Symbol("V_Bus_$b")] = zeros(Float64, 24)
    df_voltajes_cont_a[!, Symbol("V_Bus_$b")] = zeros(Float64, 24)
    df_voltajes_cont_b[!, Symbol("V_Bus_$b")] = zeros(Float64, 24)
end

println("=== Ejecutando Análisis de Flujos y Contingencias N-1 ===")

for h in 1:24
    demanda_actual_pu = df_perfiles.Demanda_normalizada[h]
    
    # A) Actualizar potencias en los 3 sistemas
    for current_sys in [sys_base, sys_cont_a, sys_cont_b]
        for (load_comp, p_base_val, q_base_val) in base_loads
            current_load = get_component(PowerLoad, current_sys, get_name(load_comp))
            set_active_power!(current_load, p_base_val * λ_load * demanda_actual_pu)
            set_reactive_power!(current_load, q_base_val * λ_load * demanda_actual_pu)
        end
        
        for g in get_components(ThermalStandard, current_sys)
            nombre = get_name(g)
            set_active_power!(g, despacho_p_print[h, nombre] / S_base)
        end
        
        g_solar = get_component(RenewableDispatch, current_sys, "gen-solar")
        set_active_power!(g_solar, despacho_p_print[h, "gen-solar"] / S_base)
    end
    
    # B) Aplicar Contingencias PERMANENTES desde las 21:00 hrs
    if h >= 22
        if h == 22
            println("-> 21:00 hrs: Aplicando contingencias (quedarán activas hasta el final del día)...")
        end
        
        # Contingencia A: Línea 2-3 
        for l in get_components(Line, sys_cont_a)
            arc = get_arc(l)
            if (get_number(get_from(arc)) == 2 && get_number(get_to(arc)) == 3) ||
               (get_number(get_from(arc)) == 3 && get_number(get_to(arc)) == 2)
                set_available!(l, false)
                break
            end
        end
        
        # Contingencia B: Gen-2
        gen2 = get_component(ThermalStandard, sys_cont_b, "gen-2")
        if get_available(gen2) 
            set_available!(gen2, false)
            bus2 = get_bus(gen2)
            set_bustype!(bus2, ACBusTypes.PQ)
        end
    end
    
    # C) Resolver Flujos de Potencia AC
    pf_base = solve_powerflow(ACPowerFlow(check_reactive_power_limits=true), sys_base)
    pf_cont_a = solve_powerflow(ACPowerFlow(check_reactive_power_limits=true), sys_cont_a)
    pf_cont_b = solve_powerflow(ACPowerFlow(check_reactive_power_limits=true), sys_cont_b)
    
    # D) Guardar magnitudes de voltaje en los DataFrames
    v_base = sort(pf_base["bus_results"], :bus_number).Vm
    v_cont_a = sort(pf_cont_a["bus_results"], :bus_number).Vm
    v_cont_b = sort(pf_cont_b["bus_results"], :bus_number).Vm
    
    for b in 1:n_buses
        df_voltajes_base[h, Symbol("V_Bus_$b")] = round(v_base[b], digits=3)
        df_voltajes_cont_a[h, Symbol("V_Bus_$b")] = round(v_cont_a[b], digits=3)
        df_voltajes_cont_b[h, Symbol("V_Bus_$b")] = round(v_cont_b[b], digits=3)
    end
end

# ==============================================================================
# CREACIÓN DE CARPETAS Y GUARDADO DE CSVS
# ==============================================================================
println("\n=== Guardando Resultados en Carpetas ===")

# CORRECCIÓN DE GUARDADO: Todo a una sola carpeta
carpeta_contingencias = joinpath(@__DIR__, "1.2.caso_contingencias")
if !isdir(carpeta_contingencias)
    mkdir(carpeta_contingencias)
end

CSV.write(joinpath(carpeta_contingencias, "voltajes_base_24h.csv"), df_voltajes_base)
CSV.write(joinpath(carpeta_contingencias, "voltajes_contA_24h.csv"), df_voltajes_cont_a)
CSV.write(joinpath(carpeta_contingencias, "voltajes_contB_24h.csv"), df_voltajes_cont_b)

println("¡Archivos generados exitosamente en la carpeta '1.2.caso_contingencias'!")