class ProjectTreeResponse {
  final ProjectNode root;

  ProjectTreeResponse({required this.root});

  factory ProjectTreeResponse.fromJson(Map<String, dynamic> json) {
    return ProjectTreeResponse(root: ProjectNode.fromJson(json));
  }
}

class ProjectNode {
  final List<ProjectNode> children;
  final String? imageUrl;
  final String? infoTxtPath;
  final bool isFolder;
  final bool isVersion;
  final String name;
  final String path;
  final String? projectId;
  final String? versionId;
  final String? storagePath;

  ProjectNode({
    required this.children,
    this.imageUrl,
    this.infoTxtPath,
    required this.isFolder,
    this.isVersion = false,
    required this.name,
    required this.path,
    this.projectId,
    this.versionId,
    this.storagePath,
  });

  factory ProjectNode.fromJson(Map<String, dynamic> json) {
    return ProjectNode(
      children:
          (json['children'] as List<dynamic>?)
              ?.map((e) => ProjectNode.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      imageUrl: (json['image_url'] as String?)?.replaceAll(RegExp(r'\?$'), ''),
      infoTxtPath: json['info_txt_path'] as String?,
      isFolder: json['is_folder'] ?? true,
      isVersion: json['is_version'] ?? false,
      name: json['name'] ?? 'Unknown',
      path: json['path'] ?? '',
      projectId: json['project_id'] as String?,
      versionId: json['version_id'] as String?,
      storagePath: json['storage_path'] as String?,
    );
  }
}
