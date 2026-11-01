// Ersatz für webOS' "webos-service": tv/service/service.js läuft so unverändert im Hauptprozess.
// Die Anfragen der App kommen über main.js hierher (Service.handlers).
const handlers = {};
function Service(name) { this.name = name; this.activityManager = { create() {} }; }
Service.prototype.register = function (method, fn, cancel) { handlers[method] = { fn, cancel }; };
Service.handlers = handlers;
module.exports = Service;
