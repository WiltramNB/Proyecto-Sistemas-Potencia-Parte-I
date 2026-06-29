# Parte I Proyecto de Sistemas de Potencia - Despacho Económico y Flujos de Potencia - Grupo 5

Este repositorio contiene la simulación de un Despacho Económico (ED) y el análisis de Flujos de Potencia AC (incluyendo contingencias N-1) para un sistema eléctrico modificado de 14 barras de la IEEE. El proyecto reemplaza un generador térmico por una planta de generación solar e incorpora perfiles horarios de demanda e irradiancia.

## 🛠️ Librerías Utilizadas
Para ejecutar estos códigos, necesitas tener instalado Julia y los siguientes paquetes:
- `PowerSystems.jl` (Para el modelado de la topología de la red)
- `PowerSimulations.jl` (Para la formulación del Despacho Económico)
- `PowerFlows.jl` (Para la simulación física de los flujos de potencia AC)
- `Ipopt.jl` (Solver de optimización no lineal)
- `Dates.jl` y `TimeSeries.jl` (Para el manejo de los perfiles horarios)
- `CSV.jl` y `DataFrames.jl` (Para el manejo, lectura y exportación de datos)

## ⚙️ Orden de Ejecución de los Códigos

⚠️ **MUY IMPORTANTE:** Los códigos deben ejecutarse en un orden específico, ya que están encadenados.

1. **Primero debes ejecutar el Código 1 (`Parte1_ED.jl`)**. 
2. **Luego debes ejecutar el Código 2 (`Parte2_Flujos_Contingencias.jl`)**.

**¿Por qué este orden?** 
El Código 2 realiza un análisis físico (Flujo de Potencia) de la red, pero para saber cuánta energía inyectar, necesita leer las consignas de generación óptimas. Estas consignas son calculadas y exportadas por el Código 1 en el archivo `1_despacho_resultados.csv`. Si intentas correr el Código 2 primero, arrojará un error porque no encontrará las instrucciones de generación.

## 📄 Descripción de los Archivos y Outputs

### 1. `Parte1_ED.jl` (Despacho Económico y Caso Base)
**Descripción:** 
Este script toma el sistema estático `.m`, aplica un aumento del 10% a la demanda, modela la planta solar y resuelve el Despacho Económico para minimizar los costos de operación durante 24 horas usando el solver Ipopt. Posteriormente, evalúa el balance de potencia y ejecuta un flujo AC para verificar los voltajes del caso base.

**Outputs (Se guardan automáticamente en la carpeta `1.1.caso_base/`):**
- `1_despacho_resultados.csv`: Puntos de operación (MW) de cada generador hora a hora.
- `2_costo_minimizado.csv`: Costo total de operación del sistema al final del día.
- `3_demanda_resultados.csv`: Verificación del balance entre generación y demanda.
- `4_lambda_resultados.csv`: Costo marginal de la energía ($\lambda$) en USD/MWh.
- `5_voltajes_resultados.csv`: Perfil de voltajes en por unidad (pu) para las 14 barras.

### 2. `Parte2_Flujos_Contingencias.jl` (Análisis de Contingencias)
**Descripción:** 
Este script lee los resultados del despacho del Código 1 y simula el comportamiento físico de la red bajo tres escenarios distintos para observar cómo reaccionan los voltajes. A partir de la hora 21:00, se aplican dos fallas graves en el sistema.

**Outputs (Se guardan automáticamente en la carpeta `1.2.caso_contingencias/`):**
- `voltajes_base_24h.csv`: Voltajes bajo operación normal (sin fallas).
- `voltajes_contA_24h.csv`: Voltajes tras la **Contingencia A** (Salida permanente de la Línea 2-3).
- `voltajes_contB_24h.csv`: Voltajes tras la **Contingencia B** (Falla del Generador Térmico en la barra 2).