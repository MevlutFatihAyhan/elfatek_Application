class ProjectNode {
  final List<ProjectNode> children;
  final String? imageUrl;
  final String? infoTxtPath;
  final bool isFolder;
  final String name;
  final String path;
  final String? projectId;
  final List<Map<String, dynamic>>? files;

  ProjectNode({
    required this.children,
    this.imageUrl,
    this.infoTxtPath,
    required this.isFolder,
    required this.name,
    required this.path,
    this.projectId,
    this.files,
  });

  factory ProjectNode.fromJson(Map<String, dynamic> json) {
    return ProjectNode(
      children:
          (json['children'] as List<dynamic>?)
              ?.map((e) => ProjectNode.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      imageUrl: json['image_url'] as String?,
      infoTxtPath: json['info_txt_path'] as String?,
      isFolder: json['is_folder'] as bool,
      name: json['name'] as String,
      path: json['path'] as String,
      projectId: json['project_id'] as String?,
      files: (json['files'] as List<dynamic>?)
          ?.map((e) => e as Map<String, dynamic>)
          .toList(),
    );
  }
}
