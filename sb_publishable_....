const SUPABASE_URL = "https://fgbyxpvpdjwogwnzmmso.supabase.co";

const SUPABASE_ANON_KEY = "sb_publishable_9p7A7DDdfAdDJxXSRPqc4Q_CvjYUanA";

const db = window.supabase.createClient(
    SUPABASE_URL,
    SUPABASE_ANON_KEY
);
// Configuración del sistema
const CR_CONFIG = {
    bucket: "project-images",

    tables: {
        projects: "projects",
        leads: "leads",
        analytics: "analytics_events",
        admins: "admin_users",
        settings: "site_settings"
    }
};

// Formato de dinero
function crMoney(value) {
    return new Intl.NumberFormat("en-US", {
        style: "currency",
        currency: "USD",
        maximumFractionDigits: 0
    }).format(Number(value || 0));
}

// Formato de porcentajes
function crPercent(value) {
    return Number(value || 0).toFixed(2) + "%";
}

// Identificador del visitante
function crVisitorId() {
    let id = localStorage.getItem("cr_visitor_id");

    if (!id) {
        id = crypto.randomUUID();
        localStorage.setItem("cr_visitor_id", id);
    }

    return id;
}

// Identificador de sesión
function crSessionId() {
    let id = sessionStorage.getItem("cr_session_id");

    if (!id) {
        id = crypto.randomUUID();
        sessionStorage.setItem("cr_session_id", id);
    }

    return id;
}

// Detectar dispositivo
function crDevice() {
    const width = window.innerWidth;

    if (width < 768) return "Móvil";
    if (width < 1100) return "Tablet";

    return "Computadora";
}

// Leer parámetros UTM
function crUTM(name) {
    const params = new URLSearchParams(window.location.search);
    return params.get(name);
}

// Registrar métricas
async function crTrack(eventName, projectId = null) {
    try {
        const { error } = await db
            .from(CR_CONFIG.tables.analytics)
            .insert({
                event_name: eventName,
                project_id: projectId,
                visitor_id: crVisitorId(),
                session_id: crSessionId(),
                page_path: window.location.pathname + window.location.hash,
                referrer: document.referrer || "Directo",
                utm_source: crUTM("utm_source"),
                utm_medium: crUTM("utm_medium"),
                utm_campaign: crUTM("utm_campaign"),
                device: crDevice()
            });

        if (error) {
            console.error("Error Analytics:", error);
        }

    } catch (error) {
        console.error("Error Analytics:", error);
    }
}

// Seguridad básica para texto HTML
function crEscape(text) {
    const div = document.createElement("div");
    div.textContent = text ?? "";
    return div.innerHTML;
}

// Limpiar nombres de archivos
function crSlugFile(name) {
    return name
        .toLowerCase()
        .replace(/[^a-z0-9.\-_]/g, "-")
        .replace(/-+/g, "-");
}
