import 'package:appflowy_editor/appflowy_editor.dart';

/// 包内已注册的可编辑块目录；结构子块由所属容器隐式启用，场景可选择子集。
enum EditorBlock {
  /// 基础正文，也是空文档、回车和删除末块的落点，必须启用。
  paragraph('paragraph'),

  /// 标题；可用级别由配置的headingLevels决定。
  heading('heading'),

  /// 带左侧引用线的文字。
  quote('quote'),

  /// 无序列表文字。
  bulletedList('bulleted_list'),

  /// 有序列表文字。
  numberedList('numbered_list'),

  /// 可勾选的待办文字。
  todoList('todo_list'),

  /// 保留源码、语言及独立历史的代码块。
  code('code'),

  /// 可承载嵌套正文的高亮块。
  callout('callout'),

  /// 表格，同时启用行和单元格结构。
  table('table'),

  /// 分割线及其外观设置。
  divider('divider'),

  /// 连续流中的分页标记。
  pageDivider('page-divider'),

  /// 独立公式。
  formula('formula'),

  /// Mermaid绘图及其源码子块。
  mermaid('mermaid'),

  /// 图片及其题注与尺寸。
  image('image'),

  /// 链接卡片。
  link('link'),

  /// 视频资源。
  video('video'),

  /// 音频资源。
  audio('audio'),

  /// 附件资源。
  attachment('attachment'),

  /// 网页卡片。
  bookmark('bookmark'),

  /// 网页嵌入。
  embed('embed'),

  /// Figma嵌入。
  figma('figma-embed'),

  /// 掘金嵌入。
  juejin('juejin-embed'),

  /// 会议引用；业务数据来自显式注入的宿主服务。
  meeting('meeting'),

  /// 任务卡片；业务数据来自显式注入的宿主服务。
  task('task'),

  /// KR引用；业务数据来自显式注入的宿主服务。
  krList('kr-list');

  /// 无嵌入和容器的文字块目录，供受限文字预设复用。
  static const text = [paragraph, heading, quote, bulletedList, numberedList, todoList];

  /// [type] 是包内正文节点的稳定类型，不是桌面flavour。
  const EditorBlock(this.type);

  /// 对应AppFlowy节点类型。
  final String type;
}

/// 编辑器共用的字符格式；配置只开放所选项。
enum EditorInlineFormat {
  /// 加粗。
  bold,

  /// 斜体。
  italic,

  /// 下划线。
  underline,

  /// 删除线。
  strikethrough,

  /// 行内等宽代码。
  code,

  /// 局部固定字号。
  fontSize,

  /// 文字颜色。
  textColor,

  /// 文字背景色。
  backgroundColor,

  /// 字体族。
  fontFamily,

  /// 字号倍率。
  fontScale,

  /// 字距。
  letterSpacing,

  /// 上标。
  superscript,

  /// 下标。
  subscript,

  /// 行内链接。
  link,

  /// 行内公式对象。
  inlineFormula,

  /// 人员及业务实体提及对象，需要实例业务端口。
  mention;

  /// 原文字预设的格式目录，不包含嵌入对象或上下标。
  static const text = [bold, italic, underline, strikethrough, code, fontSize, textColor, backgroundColor];
}

/// 键盘顶部的可选入口，包含原工具栏及“更多→常用”目录；未实现项保留占位提示。
/// 按配置顺序展示；存在可显示入口时自动在最右侧显示收起键盘，不参与配置。
/// 块、格式和业务端口仍独立约束实际操作。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final config = EditorConfiguration(keyboardToolbarItems: [
///   EditorKeyboardToolbarItem.table,
///   EditorKeyboardToolbarItem.formula,
/// ]);
/// ```
enum EditorKeyboardToolbarItem {
  /// 加号及其完整添加面板。
  addBlock,

  /// T：正文、标题和列表类型。
  blockType,

  /// Aa：已启用的字符格式与颜色。
  textStyle,

  /// 对齐、缩进及段落布局。
  blockLayout,

  /// 图片来源入口。
  image,

  /// @用户，需宿主选择服务。
  mention,

  /// 将当前正文或列表转换为原生待办列表，与T菜单共用事务。
  todoList,

  /// 链接卡片来源入口。
  link,

  /// 视频来源入口。
  video,

  /// 附件来源入口。
  attachment,

  /// 音频来源入口。
  audio,

  /// 网页卡片来源入口。
  bookmark,

  /// 网页嵌入来源入口。
  embed,

  /// 掘金网页来源入口。
  juejin,

  /// Figma网页来源入口。
  figma,

  /// 新建2×2表格。
  table,

  /// 新建高亮块。
  callout,

  /// 选择并引用会议，需宿主选择服务。
  meeting,

  /// 新建独立公式。
  formula,

  /// 新建Mermaid代码绘图。
  mermaid,

  /// 在当前位置插入行内公式。
  inlineFormula,

  /// 设置外观后插入分割线。
  divider,

  /// 在根级位置插入分页符。
  pageDivider,

  /// 电子表格占位入口，沿用更多面板的暂未支持提示，不创建正文。
  spreadsheet,

  /// 多维表格占位入口，沿用更多面板的暂未支持提示，不创建正文。
  multiTable,

  /// 思维导图占位入口，沿用更多面板的暂未支持提示，不创建正文。
  mindMap;

  /// 原键盘工具栏的六个默认菜单及顺序；常用动作可由调用方显式加入。
  /// 收起键盘由非空工具栏自动附加，不属于此列表。
  static const defaults = [addBlock, blockType, textStyle, blockLayout, image, mention];
}

/// 不可变的实例编辑能力；块列表为完整选择，空格式集表示禁用全部字符格式。
/// 本地会话不提供块锁；协同预设保留既有块、属性及宿主能力。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final config = EditorConfiguration(
///   blocks: [EditorBlock.paragraph, EditorBlock.heading],
///   headingLevels: {1, 3},
///   inlineFormats: {EditorInlineFormat.bold},
///   keyboardToolbarItems: [EditorKeyboardToolbarItem.blockType],
///   listConversionContainerTypes: {'custom-section'},
/// );
/// final editor = LocalEditorController(configuration: config);
/// await editor.close();
/// final imported = EditorConfiguration.document.withHost(
///   preservedAttributes: {'entryId'}, listContainers: {'custom-section'},
/// );
/// ```
final class EditorConfiguration {
  /// 离线与协同字号菜单共用的默认像素值，保持相同顺序。
  static const _defaultFontSizes = [12, 16, 20, 24, 28, 32, 36];

  /// [blocks] 为无重复的块集合，必须包含paragraph；类型菜单按此顺序，标题家族按级别排序。
  /// [headingLevels] 为1～9中的子集，默认全部级别，保留桌面/历史正文能力；移动菜单最多显示H6。
  /// 禁用heading时不产生标题入口。
  /// [progressiveHeadingMenu]为true时T菜单从H1～H3逐级展开到H6；false直接展示允许的级别。
  /// 默认true，离线与协同共用同一规则；不改变正文支持的标题级别。
  /// [inlineFormats] 为启用的字符格式，默认全部本地格式。
  /// [alignments] 为left/center/right/justify/distributed子集，空集合隐藏对齐命令。
  /// [fontSizes] 为字号菜单与命令允许的像素值，须为1～4096的整数且无重复。
  /// [structuralIndentation]默认true；false禁止原生真实嵌套缩进，仍保留已配置的平面缩进。
  /// [paragraphLayout]默认false；为纯文字场景开放平面缩进及块背景色，不开启复杂块。
  /// [blockConversionPreservedAttributes]为类型转换时保留的宿主属性键，默认空；不得覆盖目标类型的内置属性。
  /// [nextParagraphStyle] 控制下一段样式入口，默认true。
  /// [lineHeight] 控制行高写入，默认true，允许1～3倍。
  /// [keyboardToolbarItems] 选择键盘顶部入口及顺序，默认原六项；不能重复，空列表隐藏整条工具栏。
  /// 有实际可显示的菜单时自动在最右侧附加收起键盘，不由列表配置。
  /// 菜单展示不改变块/格式能力、快捷输入或其他插入入口。
  /// [listConversionContainerTypes]显式允许无Delta结构容器中的同父扁平列表互换类型，默认空。
  /// 类型须为非空字符串；不注册块、不扩展Enter/Backspace或缩进范围，也不允许跨父容器转换。
  /// [listIndentContainerTypes]独立授权无Delta父容器内同父扁平列表缩进、Enter及行首Backspace，默认空。
  /// [maxCharacters] 为不含段落分隔换行的正整数UTF-16正文上限，[maxBlocks] 为正整数正文节点上限（含结构子块）。
  /// 所有集合构造时复制；非法配置抛出ArgumentError，不创建编辑资源。
  factory EditorConfiguration({
    Iterable<EditorBlock> blocks = EditorBlock.values,
    Iterable<int> headingLevels = const {1, 2, 3, 4, 5, 6, 7, 8, 9},
    bool progressiveHeadingMenu = true,
    Iterable<EditorInlineFormat> inlineFormats = EditorInlineFormat.values,
    Iterable<String> alignments = const {'left', 'center', 'right', 'justify', 'distributed'},
    Iterable<int> fontSizes = _defaultFontSizes,
    bool paragraphLayout = false,
    bool structuralIndentation = true,
    Iterable<String> blockConversionPreservedAttributes = const {},
    bool nextParagraphStyle = true,
    bool lineHeight = true,
    Iterable<EditorKeyboardToolbarItem> keyboardToolbarItems = EditorKeyboardToolbarItem.defaults,
    Iterable<String> listConversionContainerTypes = const {},
    Iterable<String> listIndentContainerTypes = const {},
    int maxCharacters = 100000,
    int maxBlocks = 500,
  }) {
    final selected = List<EditorBlock>.unmodifiable(blocks);
    final levels = Set<int>.unmodifiable(headingLevels);
    final sizes = List<int>.unmodifiable(fontSizes);
    final aligns = Set<String>.unmodifiable(alignments);
    final formats = Set<EditorInlineFormat>.unmodifiable(inlineFormats);
    final toolbarItems = List<EditorKeyboardToolbarItem>.unmodifiable(keyboardToolbarItems);
    final listContainers = Set<String>.unmodifiable(listConversionContainerTypes);
    final indentContainers = Set<String>.unmodifiable(listIndentContainerTypes);
    final conversionAttributes = Set<String>.unmodifiable(blockConversionPreservedAttributes);
    if (toolbarItems.toSet().length != toolbarItems.length ||
        !selected.contains(EditorBlock.paragraph) ||
        selected.toSet().length != selected.length ||
        levels.any((level) => level < 1 || level > 9) ||
        (selected.contains(EditorBlock.heading) && levels.isEmpty) ||
        aligns.any((value) => !const {'left', 'center', 'right', 'justify', 'distributed'}.contains(value)) ||
        sizes.toSet().length != sizes.length ||
        sizes.any((size) => size < 1 || size > 4096) ||
        (formats.contains(EditorInlineFormat.fontSize) && sizes.isEmpty) ||
        listContainers.any((type) => type.trim().isEmpty) ||
        indentContainers.any((type) => type.trim().isEmpty) ||
        conversionAttributes.any((key) => key.trim().isEmpty) ||
        maxCharacters < 1 ||
        maxBlocks < 1) {
      throw ArgumentError('编辑能力配置无效');
    }
    return EditorConfiguration._(
      selected,
      levels,
      formats,
      aligns,
      sizes,
      nextParagraphStyle,
      lineHeight,
      maxCharacters,
      maxBlocks,
      false,
      keyboardToolbarItems: toolbarItems,
      listConversionContainerTypes: listContainers,
      listIndentContainerTypes: indentContainers,
      paragraphLayout: paragraphLayout,
      structuralIndentation: structuralIndentation,
      progressiveHeadingMenu: progressiveHeadingMenu,
      blockConversionPreservedAttributes: conversionAttributes,
    );
  }

  /// 保存已冻结的[blocks]/[headingLevels]/[inlineFormats]/[alignments]/[fontSizes]。
  /// [progressiveHeadingMenu]控制标题菜单逐级展示，默认true且不区分数据来源。
  /// [nextParagraphStyle]/[lineHeight]控制段落命令，[maxCharacters]/[maxBlocks]限制容量。
  /// [documentFeatures]仅用于保留原协同装配，不能由本地入口开启。
  /// [keyboardToolbarItems]为冻结的工具栏入口及顺序，默认原六项。
  /// [listConversionContainerTypes]为冻结的列表类型转换父容器集合，默认空，不转移任何编辑资源。
  /// [listIndentContainerTypes]为冻结的平面列表编辑父容器集合，默认空。
  /// [structuralIndentation]控制真实嵌套缩进，默认true。
  /// [paragraphLayout]控制纯文字排版入口，[blockConversionPreservedAttributes]为冻结的宿主保留属性键。
  const EditorConfiguration._(
    this.blocks,
    this.headingLevels,
    this.inlineFormats,
    this.alignments,
    this.fontSizes,
    this.nextParagraphStyle,
    this.lineHeight,
    this.maxCharacters,
    this.maxBlocks,
    this.documentFeatures, {
    this.keyboardToolbarItems = EditorKeyboardToolbarItem.defaults,
    this.listConversionContainerTypes = const {},
    this.listIndentContainerTypes = const {},
    this.paragraphLayout = false,
    this.structuralIndentation = true,
    this.progressiveHeadingMenu = true,
    this.blockConversionPreservedAttributes = const {},
  });

  /// 协同文档的兼容预设；字号菜单与离线场景共用默认像素值。
  /// 保留复杂块、上下标、布局和宿主命令，字符格式仍经公共命令提交。
  static const document = EditorConfiguration._(
    EditorBlock.values,
    {1, 2, 3, 4, 5, 6, 7, 8, 9},
    {
      EditorInlineFormat.bold,
      EditorInlineFormat.italic,
      EditorInlineFormat.underline,
      EditorInlineFormat.strikethrough,
      EditorInlineFormat.code,
      EditorInlineFormat.fontSize,
      EditorInlineFormat.textColor,
      EditorInlineFormat.backgroundColor,
      EditorInlineFormat.fontFamily,
      EditorInlineFormat.fontScale,
      EditorInlineFormat.letterSpacing,
      EditorInlineFormat.superscript,
      EditorInlineFormat.subscript,
      EditorInlineFormat.link,
      EditorInlineFormat.inlineFormula,
      EditorInlineFormat.mention,
    },
    {'left', 'center', 'right', 'justify', 'distributed'},
    _defaultFontSizes,
    true,
    true,
    100000,
    500,
    true,
  );

  /// 默认离线全部块能力；不创建同步、块锁或全局业务服务。
  static final local = EditorConfiguration();

  /// 返回延续当前全部能力的宿主配置副本，不修改本实例或创建编辑资源。
  /// [preservedAttributes]合并类型转换须保留的业务字段；[listContainers]合并获准同父列表转换的结构容器。
  /// [listIndentContainers]合并获准平面列表缩进、Enter及Backspace的结构容器。
  /// [structuralIndentation]为null时沿用当前值；false可为仅接受文字叶块的宿主关闭真实嵌套快捷键。
  /// 三个集合均复制并冻结；空白键抛ArgumentError，其余格式、容量与协同兼容开关保持。
  EditorConfiguration withHost({
    Iterable<String> preservedAttributes = const {},
    Iterable<String> listContainers = const {},
    Iterable<String> listIndentContainers = const {},
    bool? structuralIndentation,
  }) {
    final attributes = Set<String>.unmodifiable({...blockConversionPreservedAttributes, ...preservedAttributes});
    final containers = Set<String>.unmodifiable({...listConversionContainerTypes, ...listContainers});
    final indentContainers = Set<String>.unmodifiable({...listIndentContainerTypes, ...listIndentContainers});
    if ([...attributes, ...containers, ...indentContainers].any((key) => key.trim().isEmpty)) {
      throw ArgumentError('宿主字段和结构容器类型不能为空');
    }
    return EditorConfiguration._(
      blocks,
      headingLevels,
      inlineFormats,
      alignments,
      fontSizes,
      nextParagraphStyle,
      lineHeight,
      maxCharacters,
      maxBlocks,
      documentFeatures,
      keyboardToolbarItems: keyboardToolbarItems,
      listConversionContainerTypes: containers,
      listIndentContainerTypes: indentContainers,
      paragraphLayout: paragraphLayout,
      structuralIndentation: structuralIndentation ?? this.structuralIndentation,
      progressiveHeadingMenu: progressiveHeadingMenu,
      blockConversionPreservedAttributes: attributes,
    );
  }

  /// 兼容原文字场景的可选预设，调用方可显式保留六类文字块与H1～H4。
  static final text = EditorConfiguration(
    blocks: EditorBlock.text,
    inlineFormats: EditorInlineFormat.text,
    headingLevels: {1, 2, 3, 4},
    alignments: {'left', 'center', 'right', 'justify'},
  );

  /// 是否包含非文字块，决定复杂编辑菜单和排版能力；不代表连接协同。
  bool get hasComplexBlocks => documentFeatures || blocks.any((block) => !EditorBlock.text.contains(block));

  /// 标题菜单是否逐级展开；离线与协同均读取同一配置值。
  bool get usesProgressiveHeadingMenu => progressiveHeadingMenu;

  /// 是否显示缩进及块背景；纯文字场景可单独开启，不注册复杂块。
  bool get hasParagraphLayout => hasComplexBlocks || paragraphLayout;

  /// 是否需要嵌套/行内对象的事务和渲染支持，具体块仍按blocks逐一校验。
  bool get usesRichDocument =>
      hasComplexBlocks || inlineFormats.any((format) => !EditorInlineFormat.text.contains(format));

  /// 启用块及其菜单顺序；正文必须保留。
  final List<EditorBlock> blocks;

  /// 启用的标题级别，支持1～9的非连续集合以保留正文能力；移动菜单只展示其中H1～H6。
  final Set<int> headingLevels;

  /// T菜单逐级展示开关，默认true，不修改正文或允许的标题级别。
  final bool progressiveHeadingMenu;

  /// 启用的字符格式；空集合不显示Aa入口。
  final Set<EditorInlineFormat> inlineFormats;

  /// 可用对齐值；空集合不显示对齐按钮。
  final Set<String> alignments;

  /// 局部字号的菜单值及命令校验值。
  final List<int> fontSizes;

  /// 键盘顶部可显示的入口及顺序，默认原六项；本实例拥有不可变副本，空列表隐藏整条工具栏。
  /// 实际展示须满足块/格式能力；非空时自动在最右侧附加收起键盘，全部被过滤时隐藏整条。
  final List<EditorKeyboardToolbarItem> keyboardToolbarItems;

  /// 显式获准参与列表类型转换的无Delta父容器类型，默认空且由本实例持有不可变副本。
  /// 仅扩展同父扁平列表间的类型互换；根级和高亮容器沿用默认能力。
  /// 不注册自定义块，不扩展Enter、Backspace或缩进，也不允许有正文的真实嵌套父列表。
  final Set<String> listConversionContainerTypes;

  /// 显式授权缩进、Enter和行首Backspace的无Delta父容器；仅同父扁平列表，默认空，不产生真实嵌套。
  final Set<String> listIndentContainerTypes;

  /// 是否允许原生真实嵌套缩进，默认true；false仍可使用获准的平面缩进。
  final bool structuralIndentation;

  /// 纯文字场景是否开放平面缩进及块背景，默认false；不改变正文结构能力。
  final bool paragraphLayout;

  /// 类型转换保留的宿主属性键；不可变副本，默认空，不覆盖目标类型的内置属性。
  final Set<String> blockConversionPreservedAttributes;

  /// 是否开放下一段样式设置。
  final bool nextParagraphStyle;

  /// 是否允许1～3倍行高写入。
  final bool lineHeight;

  /// 本地正文UTF-16单元上限，不计段落分隔换行。
  final int maxCharacters;

  /// 本地正文节点数量上限；富内容包含表格行、单元格与绘图源码等结构节点。
  final int maxBlocks;

  /// 兼容原协同能力，包括复杂块和业务服务；本地入口明确拒绝此预设。
  final bool documentFeatures;

  /// 校验[type]及可选[level]是否启用；根节点与内部结构不作为菜单项。
  bool allowsBlock(String type, {int? level}) =>
      (documentFeatures ||
          blocks.any((block) => block.type == type) ||
          (const {'table-row', 'table-cell'}.contains(type) && blocks.contains(EditorBlock.table)) ||
          (type == 'mermaid-textarea' && blocks.contains(EditorBlock.mermaid))) &&
      (type != 'heading' || headingLevels.contains(level ?? 1));

  /// 检查字符属性[key]的命令是否启用；未知属性仅兼容原协同场景。
  bool allowsFormat(String key) {
    final format = <String, EditorInlineFormat>{
      AppFlowyRichTextKeys.bold: EditorInlineFormat.bold,
      AppFlowyRichTextKeys.italic: EditorInlineFormat.italic,
      AppFlowyRichTextKeys.underline: EditorInlineFormat.underline,
      AppFlowyRichTextKeys.strikethrough: EditorInlineFormat.strikethrough,
      AppFlowyRichTextKeys.code: EditorInlineFormat.code,
      AppFlowyRichTextKeys.textColor: EditorInlineFormat.textColor,
      AppFlowyRichTextKeys.backgroundColor: EditorInlineFormat.backgroundColor,
      't:px': EditorInlineFormat.fontSize,
      's:fontSize': EditorInlineFormat.fontSize,
      't:ff': EditorInlineFormat.fontFamily,
      's:fontFamily': EditorInlineFormat.fontFamily,
      't:fs': EditorInlineFormat.fontScale,
      't:ls': EditorInlineFormat.letterSpacing,
      's:letterSpacing': EditorInlineFormat.letterSpacing,
      'cses_superscript': EditorInlineFormat.superscript,
      'cses_subscript': EditorInlineFormat.subscript,
      AppFlowyRichTextKeys.href: EditorInlineFormat.link,
      'cses_inline_latex': EditorInlineFormat.inlineFormula,
      'cses_inline_mention': EditorInlineFormat.mention,
      'cses_mention_id': EditorInlineFormat.mention,
      'cses_mention_type': EditorInlineFormat.mention,
      'cses_mention_attributes': EditorInlineFormat.mention,
    }[key];
    return format == null ? documentFeatures : inlineFormats.contains(format);
  }

  /// 校验借用[attributes]中的字符写入；清除属性允许撤销，未知属性仍拒绝。
  bool allowsTextAttributes(Map<String, dynamic> attributes) => attributes.entries.every((entry) {
    if (entry.value == null) return true;
    if (!allowsFormat(entry.key)) return false;
    if (entry.key == 't:px' && entry.value != null && !documentFeatures) return fontSizes.contains(entry.value);
    if (entry.key == 's:fontSize' && entry.value != null && !documentFeatures) return false;
    return true;
  });

  /// 是否存在任何可显示的布局命令。
  bool get hasLayout => hasParagraphLayout || alignments.isNotEmpty || nextParagraphStyle;
}
