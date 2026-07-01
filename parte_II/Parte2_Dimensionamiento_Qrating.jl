using PowerSystems, PowerFlows
using CSV, DataFrames, Dates

# ---------------------------------------------------------------------------
# 1. Reconstrucción del sistema
# ---------------------------------------------------------------------------
sys = System(joinpath(@__DIR__, "IEEE_14_Bus_Proyecto.m"))
S_base = get_base_power(sys)

λ_load = 1.10
cargas = collect(get_components(PowerLoad, sys))
base_loads = [(load, get_active_power(load), get_reactive_power(load)) for load in cargas]
for (load, p_base, q_base) in base_loads
    set_active_power!(load, p_base * λ_load)
    set_reactive_power!(load, q_base * λ_load)
end

g3 = get_component(ThermalStandard, sys, "gen-3")
bus_solar = get_bus(g3); remove_component!(sys, g3)
set_bustype!(bus_solar, ACBusTypes.PQ)
add_component!(sys, RenewableDispatch(
    name="gen-solar", available=true, bus=bus_solar,
    active_power=0.0, reactive_power=0.0, rating=1.0,
    prime_mover_type=PrimeMovers.PVe,
    reactive_power_limits=(min=0.0, max=0.0), power_factor=1.0,
    operation_cost=TwoPartCost(VariableCost(0.0), 0.0), base_power=S_base))

df_perfiles = CSV.read(joinpath(@__DIR__, "perfiles_normalizados.csv"), DataFrame)

# --- PATH CORREGIDO ---
despacho = CSV.read(joinpath(@__DIR__, "..", "parte_I", "1.1.caso_base", "1_despacho_resultados.csv"), DataFrame)

# ---------------------------------------------------------------------------
# 2. Fijar el sistema en la HORA PEAK con la contingencia (a) aplicada
# ---------------------------------------------------------------------------
H_PEAK = 22                                   # h=22 -> 21:00 (demanda máxima)
demanda_pu = df_perfiles.Demanda_normalizada[H_PEAK]

for (load_comp, p_base, q_base) in base_loads
    cl = get_component(PowerLoad, sys, get_name(load_comp))
    set_active_power!(cl,   p_base * λ_load * demanda_pu)
    set_reactive_power!(cl, q_base * λ_load * demanda_pu)
end
for g in get_components(ThermalStandard, sys)
    set_active_power!(g, despacho[H_PEAK, get_name(g)] / S_base)
end
set_active_power!(get_component(RenewableDispatch, sys, "gen-solar"),
                  despacho[H_PEAK, "gen-solar"] / S_base)

# salida de la línea 2-3
for l in get_components(Line, sys)
    arc = get_arc(l)
    if Set((get_number(get_from(arc)), get_number(get_to(arc)))) == Set((2, 3))
        set_available!(l, false); break
    end
end

# ---------------------------------------------------------------------------
# 3. Instalar compensador con un rating dado y resolver el flujo AC
# ---------------------------------------------------------------------------
function evaluar_rating(sistema_base, q_rating; vset=1.00)
    s = deepcopy(sistema_base)
    bus3 = get_bus(get_component(RenewableDispatch, s, "gen-solar"))
    set_bustype!(bus3, ACBusTypes.PV)
    set_magnitude!(bus3, vset)
    add_component!(s, ThermalStandard(
        name="comp-statcom-b3", available=true, status=true, bus=bus3,
        active_power=0.0, reactive_power=0.0, rating=q_rating,
        active_power_limits=(min=0.0, max=1e-4),
        reactive_power_limits=(min=-q_rating, max=q_rating),
        ramp_limits=nothing, time_limits=nothing,
        operation_cost=ThreePartCost(VariableCost(0.0), 0.0, 0.0, 0.0),
        base_power=get_base_power(s),
        prime_mover_type=PrimeMovers.BA, fuel=ThermalFuels.OTHER))
    pf = ACPowerFlow(check_reactive_power_limits=true)
    V = sort(solve_powerflow(pf, s)["bus_results"], :bus_number).Vm
    return minimum(V), argmin(V), maximum(V), count(<(0.95), V)
end

# ---------------------------------------------------------------------------
# 4. BARRIDO del rating: del menor al mayor hasta cumplir la norma
# ---------------------------------------------------------------------------
println("\nRealizando barrido de Q_rating (de 10 a 120 MVAr)...")

q_ratings = Float64[]
min_v = Float64[]
min_v_bus = Int[]
max_v = Float64[]
barras_fuera = Int[]
cumple = String[]

for q in 0.10:0.05:1.20                      # de 10 a 120 MVAr en pasos de 5
    mn, ib, mx, nf = evaluar_rating(sys, q)
    ok = (mn >= 0.95) && (mx <= 1.05)
    
    push!(q_ratings, q*100)
    push!(min_v, mn)
    push!(min_v_bus, ib)
    push!(max_v, mx)
    push!(barras_fuera, nf)
    push!(cumple, ok ? "SI" : "NO")
end

# ---------------------------------------------------------------------------
# 5. Creación del CSV de Resultados
# ---------------------------------------------------------------------------
df_qrating = DataFrame(
    Q_rating_MVAr = q_ratings,
    V_min_pu = round.(min_v, digits=4),
    Bus_V_min = min_v_bus,
    V_max_pu = round.(max_v, digits=4),
    Barras_Bajo_095 = barras_fuera,
    Cumple_Norma = cumple
)

carpeta_salida = joinpath(@__DIR__, "analisis_propuestas")
if !isdir(carpeta_salida)
    mkdir(carpeta_salida)
end

ruta_csv = joinpath(carpeta_salida, "resultados_dimensionamiento_qrating.csv")
CSV.write(ruta_csv, df_qrating)

println("Simulación finalizada. Archivo generado en: $ruta_csv")