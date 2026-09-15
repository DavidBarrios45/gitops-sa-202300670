// Script de k6 que corre DENTRO del AnalysisTemplate en cada paso del canary
// (ver ../templates/analysistemplate.yaml). Combina, en este orden, los tres
// niveles de validación que exige el enunciado (sección 3.2):
//
//   1. Humo:        GET /health del api-gateway candidato -> 200
//   2. Integración: login + consulta GraphQL a catalogo + (si hay stock)
//                   creación de un pedido -- SIEMPRE contra el Service
//                   CANARIO (BASE_URL), nunca el estable ni el Ingress.
//   3. Carga:       fase de VUs con umbrales duros (abortOnFail) sobre
//                   /health: tasa de error < 1% y p95 < 500ms.
//
// Si cualquiera de los tres falla, el proceso sale con código != 0 =>
// AnalysisRun "Failed" => Rollout "Degraded" => abort automático del canary
// (ver P8/PLAN.md hallazgo #4: el abort de Rollouts se complementa con un PR
// de revert automático porque Git seguiría apuntando al tag defectuoso).
//
// Justificación de los umbrales (también documentada en el informe de
// incidente y en la documentación técnica):
//   - tasa de error < 1%: presupuesto de error de un SLO de 99% mensual.
//   - p95 < 500ms: punto en que un usuario percibe lentitud en un gateway
//     que solo proxea (sin lógica de negocio propia).
import http from "k6/http";
import { check, fail } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://sa-platform-api-gateway-canary:8080";
const ERROR_RATE_THRESHOLD = __ENV.ERROR_RATE_THRESHOLD || "0.01";
const P95_THRESHOLD_MS = __ENV.P95_THRESHOLD_MS || "500";
const VUS = parseInt(__ENV.VUS || "5", 10);
const DURATION = `${__ENV.DURATION_SECONDS || "20"}s`;

export const options = {
  scenarios: {
    carga: {
      executor: "constant-vus",
      vus: VUS,
      duration: DURATION,
    },
  },
  thresholds: {
    http_req_failed: [
      { threshold: `rate<${ERROR_RATE_THRESHOLD}`, abortOnFail: true, delayAbortEval: "15s" },
    ],
    http_req_duration: [
      { threshold: `p(95)<${P95_THRESHOLD_MS}`, abortOnFail: true, delayAbortEval: "15s" },
    ],
  },
};

// setup() corre UNA vez, antes de la fase de carga: aquí van humo + integración.
// Si algo falla aquí, k6 sale con código != 0 y el Job del AnalysisRun queda
// en Failed de inmediato, sin gastar tiempo en la fase de carga.
export function setup() {
  // 1. Humo
  const health = http.get(`${BASE_URL}/health`);
  if (!check(health, { "smoke: /health responde 200": (r) => r.status === 200 })) {
    fail(`smoke check fallo: /health devolvio ${health.status}`);
  }

  // 2. Integración: recorte real del flujo de negocio contra el canario
  const correo = `canary-check-${Date.now()}@example.com`;
  const registro = http.post(
    `${BASE_URL}/auth/register`,
    JSON.stringify({ nombre: "Canary Check", correo, password: "clave12345" }),
    { headers: { "Content-Type": "application/json" } },
  );
  if (!check(registro, { "integracion: registro 201": (r) => r.status === 201 })) {
    fail(`integracion fallo: /auth/register devolvio ${registro.status}`);
  }

  const login = http.post(
    `${BASE_URL}/auth/login`,
    JSON.stringify({ correo, password: "clave12345" }),
    { headers: { "Content-Type": "application/json" } },
  );
  if (!check(login, { "integracion: login 200": (r) => r.status === 200 })) {
    fail(`integracion fallo: /auth/login devolvio ${login.status}`);
  }
  const token = login.json("token");

  const catalogoQuery = http.post(
    `${BASE_URL}/catalogo/graphql`,
    JSON.stringify({ query: "{ productos { id nombre precio } }" }),
    { headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` } },
  );
  if (
    !check(catalogoQuery, {
      "integracion: catalogo/graphql 200": (r) => r.status === 200,
      "integracion: catalogo/graphql sin errores": (r) => !r.json("errors"),
    })
  ) {
    fail(`integracion fallo: /catalogo/graphql devolvio ${catalogoQuery.status} ${catalogoQuery.body}`);
  }

  // Creación de pedido: solo si ya hay al menos un producto sembrado (ver
  // docs/evidencias — el seed de datos de demo se aplica una vez, fuera del
  // AnalysisTemplate). Si el catálogo está vacío no se penaliza el gate por
  // un problema de datos de entorno, no de la versión candidata.
  const productos = catalogoQuery.json("data.productos") || [];
  if (productos.length > 0) {
    const pedido = http.post(
      `${BASE_URL}/pedidos/graphql`,
      JSON.stringify({
        query: `mutation($input: PedidoInput!) { crearPedido(input: $input) { id estado total } }`,
        variables: { input: { items: [{ productoId: productos[0].id, cantidad: 1 }] } },
      }),
      { headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` } },
    );
    if (
      !check(pedido, {
        "integracion: crearPedido 200": (r) => r.status === 200,
        "integracion: crearPedido sin errores": (r) => !r.json("errors"),
      })
    ) {
      fail(`integracion fallo: crearPedido devolvio ${pedido.status} ${pedido.body}`);
    }
  }

  return {};
}

// default() es la fase de CARGA propiamente dicha (VUs concurrentes).
export default function () {
  const res = http.get(`${BASE_URL}/health`);
  check(res, { "carga: /health 200": (r) => r.status === 200 });
}
