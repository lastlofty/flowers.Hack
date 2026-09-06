#!/usr/bin/env python3
"""OpenAPI 3.x structural linter for PayBridge.

Вспомогательный модуль (многоязычность разрешена; ядро — Ruby). Читает
спецификацию как JSON из stdin (Ruby разбирает YAML и отдаёт JSON) и проверяет
структуру по стандарту OpenAPI 3: paths/операции/ответы, разрешимость $ref,
существование ссылок security. Только stdlib — без внешних зависимостей и без
каких-либо нейросетей.

Вывод: JSON { "valid": bool, "errors": [...], "warnings": [...] } в stdout.
Код возврата: 0 — валидно, 1 — есть ошибки, 2 — не удалось разобрать вход.
"""
import json
import sys

HTTP_METHODS = {"get", "post", "put", "patch", "delete", "head", "options", "trace"}


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, path, message):
        self.errors.append({"path": path, "message": message})

    def warn(self, path, message):
        self.warnings.append({"path": path, "message": message})

    def as_dict(self):
        return {
            "valid": not self.errors,
            "errors": self.errors,
            "warnings": self.warnings,
        }


def resolve_ref(doc, ref):
    """Разрешает локальный JSON-pointer вида '#/a/b/c'. None если не найден."""
    if not isinstance(ref, str) or not ref.startswith("#/"):
        return None
    node = doc
    for raw in ref[2:].split("/"):
        key = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(node, dict) and key in node:
            node = node[key]
        elif isinstance(node, list) and key.isdigit() and int(key) < len(node):
            node = node[int(key)]
        else:
            return None
    return node


def check_refs(doc, node, path, report):
    """Рекурсивно проверяет, что все $ref локальны и разрешимы."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref":
                if not isinstance(value, str) or not value.startswith("#/"):
                    report.error(path, "внешние/некорректные $ref не поддержаны: %r" % value)
                elif resolve_ref(doc, value) is None:
                    report.error(path, "$ref не разрешается: %s" % value)
            else:
                check_refs(doc, value, "%s/%s" % (path, key), report)
    elif isinstance(node, list):
        for i, item in enumerate(node):
            check_refs(doc, item, "%s/%d" % (path, i), report)


def check_operation(op, path, report):
    if not isinstance(op, dict):
        report.error(path, "операция должна быть объектом")
        return
    responses = op.get("responses")
    if not isinstance(responses, dict) or not responses:
        report.error(path + "/responses", "responses обязателен и должен быть непустым объектом")
        return
    for code in responses:
        if code != "default" and not (len(str(code)) == 3 and str(code).isdigit()):
            report.error(path + "/responses", "недопустимый код ответа: %r" % code)


def check_security(doc, report):
    schemes = (doc.get("components") or {}).get("securitySchemes") or {}

    def check_requirement(req, where):
        if not isinstance(req, list):
            return
        for entry in req:
            if isinstance(entry, dict):
                for name in entry:
                    if name not in schemes:
                        report.error(where, "security ссылается на несуществующую схему: %s" % name)

    if "security" in doc:
        check_requirement(doc["security"], "#/security")
    paths = doc.get("paths")
    if not isinstance(paths, dict):
        paths = {}
    for path, methods in paths.items():
        if not isinstance(methods, dict):
            continue
        for method, op in methods.items():
            if method in HTTP_METHODS and isinstance(op, dict) and "security" in op:
                check_requirement(op["security"], "#/paths/%s/%s/security" % (path, method))


def lint(doc):
    report = Report()

    if not isinstance(doc, dict):
        report.error("#", "корень спецификации должен быть объектом")
        return report

    version = str(doc.get("openapi", ""))
    if not version.startswith("3."):
        if doc.get("swagger"):
            report.error("#/swagger", "Swagger 2.0 не поддержан; нужен OpenAPI 3.x")
        else:
            report.error("#/openapi", "отсутствует или неверная версия openapi (нужна 3.x)")

    info = doc.get("info")
    if not isinstance(info, dict):
        report.warn("#/info", "раздел info отсутствует или не объект")
    else:
        for field in ("title", "version"):
            if not info.get(field):
                report.warn("#/info/%s" % field, "рекомендуется указать %s" % field)

    paths = doc.get("paths")
    if paths is None:
        report.warn("#/paths", "нет ни одного пути")
    elif not isinstance(paths, dict):
        report.error("#/paths", "paths должен быть объектом")
    else:
        for path, methods in paths.items():
            if not str(path).startswith("/"):
                report.error("#/paths/%s" % path, "путь должен начинаться с '/'")
            if not isinstance(methods, dict):
                report.error("#/paths/%s" % path, "элемент пути должен быть объектом")
                continue
            for method, op in methods.items():
                if method in HTTP_METHODS:
                    check_operation(op, "#/paths/%s/%s" % (path, method), report)

    check_security(doc, report)
    check_refs(doc, doc, "#", report)
    return report


def main():
    try:
        doc = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as exc:
        json.dump({"valid": False, "errors": [{"path": "#", "message": "невалидный JSON: %s" % exc}],
                   "warnings": []}, sys.stdout, ensure_ascii=False)
        return 2

    report = lint(doc)
    json.dump(report.as_dict(), sys.stdout, ensure_ascii=False)
    return 0 if report.as_dict()["valid"] else 1


if __name__ == "__main__":
    sys.exit(main())
