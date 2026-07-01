using PowerSystems, PowerFlows
using CSV, DataFrames, Dates

println("=== Validación de la solución (compensación en barra 3) ===")

# ---------------------------------------------------------------------------
# 1. Reconstrucción del sistema
# ---------------------------------------------------------------------------
file_path_static = joinpath(@__DIR__, "IEEE_14_Bus_Proyecto.m")
sys = System(file_path_static)
S_base = get_base_power(sys)

λ_load = 1.10
cargas = collect(get_components(PowerLoad, sys))
base_loads = [(load, get_active_power(load), get_reactive_power(load)) for load in cargas]
for (load, p_base, q_base) in base_loads
    set_active_power!(load, p_base * λ_load)
    set_reactive_power!(load, q_base * λ_load)
end

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

# ---------------------------------------------------------------------------
# 2. Despacho y perfiles
# ---------------------------------------------------------------------------
df_perfiles = CSV.read(joinpath(@__DIR__, "perfiles_normalizados.csv"), DataFrame)

# --- PATH CORREGIDO ---
ruta_despacho = joinpath(@__DIR__, "..", "parte_I", "1.1.caso_base", "1_despacho_resultados.csv")
isfile(ruta_despacho) || error("No se encontró el archivo de despacho en el nuevo path.")
despacho_p_print = CSV.read(ruta_despacho, DataFrame)

# ---------------------------------------------------------------------------
# 3. Función que instala el dispositivo de compensación en la barra 3
# ---------------------------------------------------------------------------
Q_RATING = 0.70     # 70 MVAr (dimensionado por flujo AC)
V_SET    = 1.00     # consigna de voltaje en la barra 3

function instalar_compensador!(sistema; q_rating=Q_RATING, vset=V_SET)
    bus3 = get_bus(get_component(RenewableDispatch, sistema, "gen-solar"))
    set_bustype!(bus3, ACBusTypes.PV)     
    set_magnitude!(bus3, vset)           
    comp = ThermalStandard(
        name = "comp-statcom-b3",
        available = true,
        status = true,
        bus = bus3,
        active_power = 0.0,
        reactive_power = 0.0,
        rating = q_rating,
        active_power_limits = (min = 0.0, max = 1e-4),          # No entrega potencia activa
        reactive_power_limits = (min = -q_rating, max = q_rating),  # 70 MVAr
        ramp_limits = nothing,
        time_limits = nothing,
        operation_cost = ThreePartCost(VariableCost(0.0), 0.0, 0.0, 0.0),
        base_power = get_base_power(sistema),
        prime_mover_type = PrimeMovers.BA,
        fuel = ThermalFuels.OTHER)
    add_component!(sistema, comp)
    return comp
end

# ---------------------------------------------------------------------------
# 4. Dos escenarios de la contingencia (a): SIN y CON la solución
# ---------------------------------------------------------------------------
sys_sin = deepcopy(sys)               # contingencia (a) sin compensación
sys_con = deepcopy(sys)               # contingencia (a) con compensación
instalar_compensador!(sys_con)        # se instala el dispositivo en la barra 3

n_buses = length(get_components(Bus, sys))
timestamps = despacho_p_print.DateTime
df_sin = DataFrame(DateTime = timestamps)
df_con = DataFrame(DateTime = timestamps)
for b in 1:n_buses
    df_sin[!, Symbol("V_Bus_$b")] = zeros(Float64, 24)
    df_con[!, Symbol("V_Bus_$b")] = zeros(Float64, 24)
end

pf = ACPowerFlow(check_reactive_power_limits = true)

for h in 1:24
    demanda_pu = df_perfiles.Demanda_normalizada[h]

    # actualizar cargas y generación en ambos sistemas
    for current_sys in (sys_sin, sys_con)
        for (load_comp, p_base, q_base) in base_loads
            cl = get_component(PowerLoad, current_sys, get_name(load_comp))
            set_active_power!(cl,   p_base * λ_load * demanda_pu)
            set_reactive_power!(cl, q_base * λ_load * demanda_pu)
        end
        for g in get_components(ThermalStandard, current_sys)
            nombre = get_name(g)
            if nombre in names(despacho_p_print)
                set_active_power!(g, despacho_p_print[h, nombre] / S_base)
            end
        end
        gs = get_component(RenewableDispatch, current_sys, "gen-solar")
        set_active_power!(gs, despacho_p_print[h, "gen-solar"] / S_base)
    end

    # contingencia (a): salida de la línea 2-3 desde las 21:00 (h>=22)
    if h >= 22
        for current_sys in (sys_sin, sys_con)
            for l in get_components(Line, current_sys)
                arc = get_arc(l)
                if Set((get_number(get_from(arc)), get_number(get_to(arc)))) == Set((2, 3))
                    set_available!(l, false)
                    break
                end
            end
        end
    end

    # resolver flujos AC
    pf_sin = solve_powerflow(pf, sys_sin)
    pf_con = solve_powerflow(pf, sys_con)
    v_sin = sort(pf_sin["bus_results"], :bus_number).Vm
    v_con = sort(pf_con["bus_results"], :bus_number).Vm
    for b in 1:n_buses
        df_sin[h, Symbol("V_Bus_$b")] = round(v_sin[b], digits=4)
        df_con[h, Symbol("V_Bus_$b")] = round(v_con[b], digits=4)
    end
end

# ---------------------------------------------------------------------------
# 5. Guardar CSVs en las nuevas carpetas
# ---------------------------------------------------------------------------
carpeta_base = joinpath(@__DIR__, "analisis_propuestas")
if !isdir(carpeta_base)
    mkdir(carpeta_base)
end

# Se crea la subcarpeta "validacion_solucion"
carpeta_val = joinpath(carpeta_base, "validacion_solucion")
if !isdir(carpeta_val)
    mkdir(carpeta_val)
end

CSV.write(joinpath(carpeta_val, "voltajes_contA_SIN_solucion.csv"), df_sin)
CSV.write(joinpath(carpeta_val, "voltajes_contA_CON_solucion.csv"), df_con)

println("\nFlujos resueltos. CSVs guardados en 'analisis_propuestas/validacion_solucion'.")