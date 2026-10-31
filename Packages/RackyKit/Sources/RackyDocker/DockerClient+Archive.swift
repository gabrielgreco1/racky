import Foundation

extension DockerClient {
    /// `GET /containers/{id}/archive?path=`: tar do caminho (arquivo ou pasta) dentro do container, em streaming.
    /// Funciona também com o container parado. `path` terminado em `/.` traz só o conteúdo da pasta.
    public func archive(_ id: String, path: String) async throws -> AsyncThrowingStream<Data, any Error> {
        let request = HTTPRequest(method: "GET", path: "/containers/\(id)/archive", query: [.init(name: "path", value: path)])
        let (_, body) = try await transport.stream(request, headTimeout: defaultTimeout, operation: "container archive")
        return body
    }

    /// `PUT /containers/{id}/archive?path=`: desempacota o tar em `path` (pasta que já existe). Funciona com o container parado;
    /// o daemon recusa montagens somente leitura.
    public func putArchive(_ id: String, path: String, tar: Data) async throws {
        var request = HTTPRequest(method: "PUT", path: "/containers/\(id)/archive", query: [.init(name: "path", value: path)])
        request.body = tar
        request.headers["Content-Type"] = "application/x-tar"
        _ = try await transport.send(request, timeout: .seconds(120), operation: "container put archive")
    }
}
