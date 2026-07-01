using PowerSystems, PowerSimulations
using Dates, TimeSeries
using Ipopt
using CSV, DataFrames
using PowerFlows 

ed_model_output = joinpath(@__DIR__, "ED_model")
if !isdir(ed_model_output)
    mkdir(ed_model_output)
end

file_path_static = joinpath(@__DIR__, "IEEE_14_Bus_Proyecto.m")
if !isfile(file_path_static)
    error("No se encontró el archivo .m en el directorio.")
end

println("Cargando sistema estático desde '$(basename(file_path_static))'...")
sys = System(file_path_static)
S_base = get_base_power(sys)

# ######################## NO MODIFICAR ESTA PONDERACIÓN ########################
λ_load = 1.10
cargas = collect(get_components(PowerLoad, sys));

for load in cargas
    set_active_power!(load, get_active_power(load) * λ_load)
    set_reactive_power!(load, get_reactive_power(load) * λ_load)
end
# ######################## NO MODIFICAR ESTA PONDERACIÓN ########################

# Sincronizar max_active_power con el nuevo active_power escalado
for load in cargas
    set_max_active_power!(load, get_active_power(load))
end

# Guardar valores post-λ para Puntos 3 y 5
base_loads = [(load, get_active_power(load), get_reactive_power(load)) for load in cargas]

# 2. Reemplazo del generador síncrono gen-3 por planta solar
gen_termico_a_retirar = get_component(ThermalStandard, sys, "gen-3") 
max_active_power_gen_a_retirar = get_max_active_power(gen_termico_a_retirar)
bus_solar = get_bus(gen_termico_a_retirar)

remove_component!(sys, gen_termico_a_retirar)
set_bustype!(bus_solar, ACBusTypes.PQ)

cap_max_gen_solar = round(max_active_power_gen_a_retirar, digits=2)

gen_solar = RenewableDispatch(
    name="gen-solar",
    available=true,
    bus=bus_solar,
    active_power=0.0,
    reactive_power=0.0,
    rating=cap_max_gen_solar, 
    prime_mover_type=PrimeMovers.PVe,
    reactive_power_limits=(min=0.0, max=0.0), 
    power_factor=1.0,
    operation_cost=TwoPartCost(VariableCost(0.0), 0.0), 
    base_power=S_base)

add_component!(sys, gen_solar)

# 3. Definición de funciones de costo
gens_termicos = sort!(collect(get_components(ThermalStandard, sys)), by=x -> get_name(x))

costos_fijos = [2100.0, 7200.0, 6250.0, 2000.0] 
costos_variables = [(0.1, 10.0), (0.06, 7.0), (0.07, 8.0), (0.5, 60.0)] 

for (i, g) in enumerate(gens_termicos)
    costo_cuadratico = VariableCost(costos_variables[i])
    costo_total = ThreePartCost(costo_cuadratico, costos_fijos[i], 0.0, 0.0)
    set_operation_cost!(g, costo_total)
end

# 4. Formulación del ED con TimeSeries
start_time = DateTime("2024-01-01T00:00:00")
timestamps = [start_time + Hour(i) for i in 0:23]

ruta_perfiles = joinpath(@__DIR__, "perfiles_normalizados.csv")
df_perfiles = CSV.read(ruta_perfiles, DataFrame)

perfil_demanda_pu = df_perfiles.Demanda_normalizada
for load in get_components(PowerLoad, sys)
    ta = TimeArray(timestamps, perfil_demanda_pu)
    add_time_series!(sys, load, SingleTimeSeries(name="max_active_power", data=ta))
end

perfil_solar_pu = df_perfiles.Irradiancia_normalizada
ta_solar = TimeArray(timestamps, perfil_solar_pu)
add_time_series!(sys, gen_solar, SingleTimeSeries(name="max_active_power", data=ta_solar))

transform_single_time_series!(sys, 24, Hour(1))

# 5. Plantilla de ED y Resolución
template_ed = template_economic_dispatch()
set_network_model!(template_ed, NetworkModel(CopperPlatePowerModel, duals=[CopperPlateBalanceConstraint]))

optimizer = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 3)
modelo_ed = DecisionModel(template_ed, sys, optimizer=optimizer, horizon=24)

println("\nConstruyendo el modelo matemático...")
build!(modelo_ed, output_dir=ed_model_output)
println("\nResolviendo el despacho económico...")
solve!(modelo_ed)

# ==============================================================================
# CREACIÓN DE CARPETA PRINCIPAL
# ==============================================================================
carpeta_resultados = joinpath(@__DIR__, "1.1.caso_base")
if !isdir(carpeta_resultados)
    mkdir(carpeta_resultados)
end

# ==============================================================================
# PUNTO 1 y 4: Extracción de Resultados
# ==============================================================================
res = ProblemResults(modelo_ed)
vars = read_variables(res)

despacho_termico = vars["ActivePowerVariable__ThermalStandard"]
despacho_solar = vars["ActivePowerVariable__RenewableDispatch"]
despacho_p = innerjoin(despacho_termico, despacho_solar, on=:DateTime)
despacho_p_print = select(despacho_p, ["DateTime"; sort(names(despacho_p)[2:end])])

for col in names(despacho_p_print)
    if col != "DateTime"
        despacho_p_print[!, col] = round.(despacho_p_print[!, col], digits=4)
    end
end

ruta_despacho = joinpath(carpeta_resultados, "1_despacho_resultados.csv")
CSV.write(ruta_despacho, despacho_p_print)

stats = read_optimizer_stats(res)
costo_total_usd = round(stats[1, :objective_value], digits=4)
println("\n---> PUNTO 2: Costo Total Minimizado (USD): ", costo_total_usd)

# NUEVO: Generar el CSV con solo el costo total minimizado
df_costo = DataFrame(Costo_Total_Minimizado_USD = [costo_total_usd])
ruta_costo = joinpath(carpeta_resultados, "2_costo_minimizado.csv")
CSV.write(ruta_costo, df_costo)

duals = read_duals(res)
lambda_pu = duals["CopperPlateBalanceConstraint__System"]
lambda_mw = DataFrame(DateTime=lambda_pu.DateTime, Lambda_MW=round.(lambda_pu[!, 2] ./ S_base, digits=4))

ruta_lambda = joinpath(carpeta_resultados, "4_lambda_resultados.csv")
CSV.write(ruta_lambda, lambda_mw)

# ==============================================================================
# PUNTO 3: Evolución de la Demanda
# ==============================================================================
println("\n---> PUNTO 3: Análisis de Demanda")

# base_loads ya tiene valores post-λ, NO multiplicar λ_load de nuevo
demanda_base_pu_total = sum(p_base for (_, p_base, _) in base_loads)
demanda_base_mw_total = demanda_base_pu_total * S_base

perfil_demanda = df_perfiles.Demanda_normalizada
demanda_horaria_mw = perfil_demanda .* demanda_base_mw_total

generacion_total_mw = [sum(Array(row[2:end])) for row in eachrow(despacho_p_print)]

df_demanda = DataFrame(
    DateTime = timestamps,
    Demanda_Total_MW = round.(demanda_horaria_mw, digits=4),
    Generacion_Total_MW = round.(generacion_total_mw, digits=4)
)

df_demanda.Satisfecha = isapprox.(df_demanda.Demanda_Total_MW, df_demanda.Generacion_Total_MW, atol=1.0)

ruta_demanda = joinpath(carpeta_resultados, "3_demanda_resultados.csv")
CSV.write(ruta_demanda, df_demanda)

show(stdout, "text/plain", df_demanda)
println("\n--- Resumen de Balance ---")
for i in 1:24
    if !df_demanda.Satisfecha[i]
        println("Hora $(i-1):00 -> DESBALANCE DETECTADO. Demanda: $(df_demanda.Demanda_Total_MW[i]) MW vs Gen: $(df_demanda.Generacion_Total_MW[i]) MW")
    end
end

# ==============================================================================
# PUNTO 5: Perfil de Voltajes
# ==============================================================================
println("\n---> PUNTO 5: Ejecutando Flujos de Potencia AC hora a hora...")

n_buses = length(get_components(Bus, sys))
df_voltajes = DataFrame(DateTime = timestamps)

for b in 1:n_buses
    df_voltajes[!, Symbol("V_Bus_$b")] = zeros(Float64, 24)
end

for h in 1:24
    demanda_actual_pu = df_perfiles.Demanda_normalizada[h]
    
    # p_base_val ya incluye λ, NO volver a multiplicar
    for (load_comp, p_base_val, q_base_val) in base_loads
        set_active_power!(load_comp, p_base_val * demanda_actual_pu)
        set_reactive_power!(load_comp, q_base_val * demanda_actual_pu)
    end
    
    for g in gens_termicos
        nombre = get_name(g)
        set_active_power!(g, despacho_p_print[h, nombre] / S_base)
    end
    
    set_active_power!(gen_solar, despacho_p_print[h, "gen-solar"] / S_base)
    
    pf_results = solve_powerflow(ACPowerFlow(check_reactive_power_limits=true), sys)
    
    v_mags = sort(pf_results["bus_results"], :bus_number).Vm
    for b in 1:n_buses
        df_voltajes[h, Symbol("V_Bus_$b")] = round(v_mags[b], digits=4)
    end
end

ruta_voltajes = joinpath(carpeta_resultados, "5_voltajes_resultados.csv")
CSV.write(ruta_voltajes, df_voltajes)

println("\nCSVs del caso base guardados en la carpeta '1.1.caso_base'.")

# ==============================================================================
# PUNTO EXTRA: Análisis del caso histórico (Sin planta fotovoltaica)
# ==============================================================================
println("\n=== Iniciando simulación del Caso Histórico (con gen-3) ===")

# 1. Cargar el sistema nuevamente desde cero
sys_hist = System(file_path_static)

# 2. Aplicar el 110% de carga y sincronizar max_active_power
cargas_hist = collect(get_components(PowerLoad, sys_hist))
for load in cargas_hist
    set_active_power!(load, get_active_power(load) * λ_load)
    set_reactive_power!(load, get_reactive_power(load) * λ_load)
    
    # Sincronización crucial para el TimeSeries
    set_max_active_power!(load, get_active_power(load))
    set_max_reactive_power!(load, get_reactive_power(load))
end

# 3. Aplicar TimeSeries a la demanda
for load in cargas_hist
    ta = TimeArray(timestamps, perfil_demanda_pu)
    add_time_series!(sys_hist, load, SingleTimeSeries(name="max_active_power", data=ta))
end
transform_single_time_series!(sys_hist, 24, Hour(1))

# 4. Definir las funciones de costo para los CINCO generadores
# Al ordenar alfabéticamente, el orden será: gen-1, gen-2, gen-3, gen-4, gen-5
gens_termicos_hist = sort!(collect(get_components(ThermalStandard, sys_hist)), by=x -> get_name(x))

# Incorporamos los costos del gen-3 en la tercera posición
# C3(P3) = 1500 + 6P3 + 0.02P3^2
costos_fijos_hist = [2100.0, 7200.0, 1500.0, 6250.0, 2000.0] 
costos_variables_hist = [(0.1, 10.0), (0.06, 7.0), (0.02, 6.0), (0.07, 8.0), (0.5, 60.0)] 

for (i, g) in enumerate(gens_termicos_hist)
    costo_cuadratico = VariableCost(costos_variables_hist[i])
    costo_total = ThreePartCost(costo_cuadratico, costos_fijos_hist[i], 0.0, 0.0)
    set_operation_cost!(g, costo_total)
end

# 5. Formular y resolver el modelo
template_ed_hist = template_economic_dispatch()
set_network_model!(template_ed_hist, NetworkModel(CopperPlatePowerModel, duals=[CopperPlateBalanceConstraint]))

# Usamos el mismo optimizador (Ipopt) ya instanciado en el código principal
modelo_ed_hist = DecisionModel(template_ed_hist, sys_hist, optimizer=optimizer, horizon=24)

println("\nConstruyendo modelo histórico...")
build!(modelo_ed_hist, output_dir=joinpath(carpeta_resultados, "ED_model_historico"))

println("\nResolviendo despacho histórico...")
solve!(modelo_ed_hist)

# 6. Extracción y guardado del costo marginal (Lambda)
res_hist = ProblemResults(modelo_ed_hist)
duals_hist = read_duals(res_hist)
lambda_pu_hist = duals_hist["CopperPlateBalanceConstraint__System"]

# Generamos el DataFrame respetando el formato solicitado
lambda_mw_hist = DataFrame(
    DateTime = lambda_pu_hist.DateTime,
    Lambda_MW = round.(lambda_pu_hist[!, 2] ./ S_base, digits=3)
)

# Guardamos el archivo en la misma carpeta del caso base
ruta_lambda_hist = joinpath(carpeta_resultados, "0_lambda_historico_resultados.csv")
CSV.write(ruta_lambda_hist, lambda_mw_hist)

println("\nCaso histórico listo. Lambda guardado en '1.1.caso_base'.")