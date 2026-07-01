using PowerSystems, PowerFlows
using CSV, DataFrames, Dates

# ---------------------------------------------------------------------------
# 1. Reconstrucción del sistema
# ---------------------------------------------------------------------------
sys0 = System(joinpath(@__DIR__, "IEEE_14_Bus_Proyecto.m"))
S_base = get_base_power(sys0)

λ_load = 1.10
cargas = collect(get_components(PowerLoad, sys0))
base_loads = [(load, get_active_power(load), get_reactive_power(load)) for load in cargas]
for (load, p_base, q_base) in base_loads
    set_active_power!(load, p_base * λ_load)
    set_reactive_power!(load, q_base * λ_load)
end

g3 = get_component(ThermalStandard, sys0, "gen-3")
bus_solar = get_bus(g3); remove_component!(sys0, g3)
set_bustype!(bus_solar, ACBusTypes.PQ)
add_component!(sys0, RenewableDispatch(
    name="gen-solar", available=true, bus=bus_solar,
    active_power=0.0, reactive_power=0.0, rating=1.0,
    prime_mover_type=PrimeMovers.PVe,
    reactive_power_limits=(min=0.0, max=0.0), power_factor=1.0,
    operation_cost=TwoPartCost(VariableCost(0.0), 0.0), base_power=S_base))

df_perfiles = CSV.read(joinpath(@__DIR__, "perfiles_normalizados.csv"), DataFrame)

# --- PATH CORREGIDO ---
despacho = CSV.read(joinpath(@__DIR__, "..", "parte_I", "1.1.caso_base", "1_despacho_resultados.csv"), DataFrame)

# ---------------------------------------------------------------------------
# 2. arma el sistema en una hora dada
# ---------------------------------------------------------------------------
function correr(h; mvar_banco=0.0, sacar_linea23=false)
    s = deepcopy(sys0)
    demanda_pu = df_perfiles.Demanda_normalizada[h]

    # cargas y generación de la hora h
    for (load_comp, p_base, q_base) in base_loads
        cl = get_component(PowerLoad, s, get_name(load_comp))
        set_active_power!(cl,   p_base * λ_load * demanda_pu)
        set_reactive_power!(cl, q_base * λ_load * demanda_pu)
    end
    for g in get_components(ThermalStandard, s)
        set_active_power!(g, despacho[h, get_name(g)] / S_base)
    end
    set_active_power!(get_component(RenewableDispatch, s, "gen-solar"),
                      despacho[h, "gen-solar"] / S_base)

    # banco de condensadores fijo en la barra 3 (susceptancia shunt constante)
    if mvar_banco > 0
        bus3 = get_bus(get_component(RenewableDispatch, s, "gen-solar"))
        B_sh = mvar_banco / S_base                 # B en pu (nominal a 1.0 pu)
        add_component!(s, FixedAdmittance(
            name = "banco_cap_b3",
            available = true,
            bus = bus3,
            Y = complex(0.0, B_sh)))               # Y = 0 + jB  (capacitivo)
    end

    # contingencia (a): línea 2-3 fuera
    if sacar_linea23
        for l in get_components(Line, s)
            arc = get_arc(l)
            if Set((get_number(get_from(arc)), get_number(get_to(arc)))) == Set((2, 3))
                set_available!(l, false); break
            end
        end
    end

    pf = ACPowerFlow(check_reactive_power_limits=true)
    V = sort(solve_powerflow(pf, s)["bus_results"], :bus_number).Vm
    return V
end

# ---------------------------------------------------------------------------
# 3. Resultados
# ---------------------------------------------------------------------------
H_PEAK  = 22                                      # 21:00 (demanda máxima)
H_VALLE = argmin(df_perfiles.Demanda_normalizada)         # hora de menor demanda
MVAR    = 70.0                                            # banco dimensionado para el peak

println("Ejecutando flujos para horas Peak ($H_PEAK) y Valle ($H_VALLE)...")

Vp_sin = correr(H_PEAK; mvar_banco=0.0,  sacar_linea23=true)
Vp_con = correr(H_PEAK; mvar_banco=MVAR, sacar_linea23=true)
Vv_sin = correr(H_VALLE; mvar_banco=0.0)
Vv_con = correr(H_VALLE; mvar_banco=MVAR)

B_sh = MVAR / S_base

# ---------------------------------------------------------------------------
# 4. Creación del CSV de Resultados
# ---------------------------------------------------------------------------
df_resultados = DataFrame(
    Escenario = [
        "Peak 21:00 - Sin Banco (Contingencia A)", 
        "Peak 21:00 - Con Banco 70 MVAr (Contingencia A)", 
        "Valle - Sin Banco (Sistema Intacto)", 
        "Valle - Con Banco 70 MVAr (Sistema Intacto)"
    ],
    V_min_pu = round.([minimum(Vp_sin), minimum(Vp_con), minimum(Vv_sin), minimum(Vv_con)], digits=4),
    Bus_V_min = [argmin(Vp_sin), argmin(Vp_con), argmin(Vv_sin), argmin(Vv_con)],
    V_max_pu = round.([maximum(Vp_sin), maximum(Vp_con), maximum(Vv_sin), maximum(Vv_con)], digits=4),
    V_bus3_pu = round.([Vp_sin[3], Vp_con[3], Vv_sin[3], Vv_con[3]], digits=4),
    Q_inyectado_MVAr = round.([0.0, B_sh*Vp_con[3]^2*S_base, 0.0, B_sh*Vv_con[3]^2*S_base], digits=2)
)

carpeta_salida = joinpath(@__DIR__, "analisis_propuestas")
if !isdir(carpeta_salida)
    mkdir(carpeta_salida)
end

ruta_csv = joinpath(carpeta_salida, "resultados_banco_condensadores.csv")
CSV.write(ruta_csv, df_resultados)

println("Simulación finalizada. Archivo generado en: $ruta_csv")