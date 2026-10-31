import Foundation

/// Trabalho de disco da árvore e do visualizador, fora do main (a UI não toca o sistema de arquivos, AR-131).
/// Um ator: leituras de pasta e de arquivo andam em fila, e nenhuma bloqueia o main thread.
public actor FilesService {
    public init() {}

    public func list(directory: String, root: String, options: FileTreeOptions, ancestorIgnored: Bool = false) -> FileListing {
        FileTreeLoader.list(directory: directory, root: root, options: options, ancestorIgnored: ancestorIgnored)
    }

    public func read(path: String) -> FileContent { FileReader.read(path: path) }

    public func highlight(text: String, language: SyntaxLanguage) -> [SyntaxSpan] {
        SyntaxHighlighter.spans(in: text, language: language)
    }

    /// Existe e é uma pasta (a árvore confere a raiz antes de trocar).
    public func isDirectory(_ path: String) -> Bool { FileTreeLoader.isDirectory(path) }
}
