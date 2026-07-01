# Proyecto de Sistemas de Potencia - Despacho Económico y Flujos de Potencia - Grupo 5

Este repositorio contiene la simulación de un Despacho Económico (ED) y el análisis de Flujos de Potencia AC (incluyendo contingencias N-1) para un sistema eléctrico modificado de 14 barras de la IEEE. El proyecto se divide en dos secciones principales: el análisis base con contingencias y la evaluación de propuestas de compensación reactiva ante escenarios críticos.

## Estructura del Proyecto

El repositorio se encuentra organizado en dos carpetas principales que separan las etapas del estudio:
* **parte_I**: Contiene los scripts encargados de calcular el Despacho Económico óptimo y evaluar los flujos de potencia bajo operación normal y ante la ocurrencia de contingencias.
* **parte_II**: Contiene los scripts orientados a proponer, dimensionar y validar soluciones de compensación reactiva (bancos de condensadores y STATCOM) para mitigar los problemas de tensión detectados en la primera etapa.

## Librerías Utilizadas

Para ejecutar estos códigos, se requiere disponer de una instalación de Julia y los siguientes paquetes:
* `PowerSystems.jl` (Para el modelado de la topología de la red)
* `PowerSimulations.jl` (Para la formulación del Despacho Económico)
* `PowerFlows.jl` (Para la simulación física de los flujos de potencia AC)
* `Ipopt.jl` (Solver de optimización no lineal)
* `Dates.jl` y `TimeSeries.jl` (Para el manejo de los perfiles horarios)
* `CSV.jl` y `DataFrames.jl` (Para el manejo, lectura y exportación de datos)

## Orden de Ejecución de los Códigos

**IMPORTANTE:** Los códigos poseen dependencias de datos entre sí, por lo que deben ejecutarse en un orden estricto para garantizar su correcto funcionamiento.

1. **Ejecución Inicial (Obligatoria):** Se debe ejecutar en primera instancia el script `Parte1_ED.jl` ubicado en la carpeta `parte_I`.
2. **Ejecuciones Secundarias:** Una vez finalizado el primer código, es posible ejecutar `Parte2_Flujos_Contingencias.jl` (dentro de `parte_I`) y cualquiera de los tres scripts ubicados en la carpeta `parte_II`.

**Justificación del orden de ejecución:**
Los códigos secundarios realizan análisis físicos (Flujos de Potencia AC) sobre la red, pero para determinar la potencia activa horaria que debe inyectar cada generador, requieren leer las consignas de generación óptimas. Estas consignas son calculadas exclusivamente por el script `Parte1_ED.jl`, el cual exporta dichos resultados al archivo `1_despacho_resultados.csv`. Si este archivo no es generado previamente, los demás scripts no tendrán la información base para operar y arrojarán error.

## Descripción de los Archivos y Outputs

### Carpeta `parte_I`

#### 1. `Parte1_ED.jl` (Despacho Económico y Caso Base)
**Descripción:**
Este script toma el sistema estático original en formato `.m`, aplica un aumento del 10% a la demanda, modela el reemplazo de una unidad térmica por una planta solar y resuelve el Despacho Económico para minimizar los costos de operación durante 24 horas usando el solver Ipopt. Adicionalmente, incluye una evaluación secundaria del caso histórico (sin planta solar) para fines comparativos de mercado.

**Outputs (Guardados automáticamente en la carpeta `parte_I/1.1.caso_base/`):**
* `1_despacho_resultados.csv`: Puntos de operación (MW) de cada generador hora a hora.
* `2_costo_minimizado.csv`: Costo total de operación del sistema al final del día.
* `3_demanda_resultados.csv`: Verificación del balance horario entre generación y demanda.
* `4_lambda_resultados.csv`: Costo marginal de la energía ($\lambda$) en USD/MWh para el escenario modificado.
* `4.1_lambda_historico_resultados.csv`: Costo marginal de la energía ($\lambda$) evaluado bajo la configuración histórica de generadores.
* `5_voltajes_resultados.csv`: Perfil de voltajes en por unidad (pu) del caso base para las 14 barras.

#### 2. `Parte2_Flujos_Contingencias.jl` (Análisis de Contingencias)
**Descripción:**
Este script lee los resultados del despacho óptimo y simula el comportamiento físico de la red bajo tres escenarios distintos. A partir de la hora 21:00, impone condiciones de falla permanente para observar el comportamiento dinámico de las tensiones nodales.

**Outputs (Guardados automáticamente en la carpeta `parte_I/1.2.caso_contingencias/`):**
* `voltajes_base_24h.csv`: Voltajes bajo operación normal (sin fallas).
* `voltajes_contA_24h.csv`: Voltajes tras la **Contingencia A** (Salida permanente de la Línea 2-3).
* `voltajes_contB_24h.csv`: Voltajes tras la **Contingencia B** (Falla del Generador Térmico en la barra 2).

---

### Carpeta `parte_II`

Todos los outputs generados por los scripts de esta sección se exportan de forma automática al directorio `parte_II/analisis_propuestas/`.

#### 1. `Parte2_Banco_Condensadores.jl`
**Descripción:**
Evalúa el comportamiento de la red ante la instalación de un banco de condensadores de capacidad fija. Su objetivo es demostrar los niveles de inyección de reactivos y advertir sobre los riesgos de sobrecompensación (sobretensión) que este elemento pasivo genera durante los horarios de demanda valle.

**Output:**
* `resultados_banco_condensadores.csv`: Cuadro comparativo de las tensiones mínimas y máximas, junto con el cálculo de la potencia reactiva efectiva inyectada.

#### 2. `Parte2_Dimensionamiento_Qrating.jl`
**Descripción:**
Realiza un barrido iterativo automático de inyección de potencia reactiva (Q rating). El objetivo es encontrar la capacidad técnica mínima requerida por un equipo de compensación dinámica para mantener todos los perfiles de voltaje del sistema dentro de la norma (0.95 - 1.05 pu) durante el escenario más severo de la Contingencia A.

**Output:**
* `resultados_dimensionamiento_qrating.csv`: Registro de las tensiones nodales más críticas por cada nivel de compensación (MVAr) evaluado.

#### 3. `Parte2_Validacion_Solucion.jl`
**Descripción:**
Implementa el dispositivo de compensación dinámica dimensionado (STATCOM) en la barra afectada y efectúa una simulación comparativa de flujos de potencia a lo largo de las 24 horas del día.

**Outputs (Guardados en la subcarpeta `validacion_solucion/`):**
* `voltajes_contA_SIN_solucion.csv`: Perfiles de voltaje horarios enfrentando la falla sin medidas de mitigación.
* `voltajes_contA_CON_solucion.csv`: Perfiles de voltaje horarios tras el accionar regulador de la solución instalada.