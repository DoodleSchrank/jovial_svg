// ignore_for_file: constant_identifier_names

/*
Copyright (c) 2021-2022, William Foote

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  * Neither the name of the copyright holder nor the names of its
    contributors may be used to endorse or promote products derived
    from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER(S) AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
*/

library jovial_svg.svg_graph;

import 'dart:math';
import 'dart:typed_data';

import 'package:jovial_misc/io_utils.dart';
import 'package:meta/meta.dart';
import 'package:quiver/collection.dart' as quiver;

import 'affine.dart';
import 'common_noui.dart';
import 'compact_noui.dart';
import 'path_noui.dart';

part 'svg_graph_text.dart';

///
/// The graph structure we get when parsing an SVG XML file.  This graph
/// is used to build a `ScalableImage` via an [SIBuilder].
///
/// If, someday, there is a desire to support some kind of DOM that lets
/// flutter code modify the parse graph, an API could be wrapped around this
/// structure.  It wouldn't be unreasonable to add a `paint(Canvas)` method
/// here, on the parse graph, to support the programmatic manipulation of the
/// parse tree.
///
class SvgParseGraph {
  final idLookup = <String, SvgNode>{};
  final SvgRoot root;
  final double? width;
  final double? height;
  final int? tintColor; // For AVD
  final SITintMode? tintMode; // For AVD

  bool _resolved = false;

  SvgParseGraph(
      this.root, this.width, this.height, this.tintColor, this.tintMode);

  ///
  /// Determine the bounds, for use in user space calculations (e.g.
  /// potentially for gradiants).  This must not be accessed before
  /// `build`, but it may be called during the build process.
  ///
  /// If a viewbox or a width/height are
  /// given in the asset, this is well-defined.  If not, we use a
  /// reasonably accurate estimate of a bounding rectangle.  The SVG spec
  /// speaks of this bounding rectangle not taking into account stroke widths,
  /// so we don't, but our estimate of font metrics is (ahem) approximate.
  /// Most SVG assets should at least provide a width/height; for those that
  /// don't, our bounding box gives a reasonable estimate.
  ///
  late final RectT userSpaceBounds = _calculateBounds();

  RectT _calculateBounds() {
    assert(_resolved);
    final w = width;
    final h = height;
    if (w != null && h != null) {
      // w and h come from width/height on the SVG asset, or, if not given,
      // from the viewBox attribute's width/height.
      final t = root.transform;
      if (t != null) {
        final b =
            _SvgBoundary(const RectT(0, 0, 1, 1)).transformed(t).getBounds();
        return RectT(0, 0, w / b.width, h / b.height);
      } else {
        return RectT(0, 0, w, h);
      }
    }
    final b = root._getUserSpaceBoundary(SvgTextAttributes.initial());
    if (b == null) {
      // e.g. because this SVG is just an empty group
      return const Rectangle(0.0, 0.0, 100.0, 100.0);
    } else {
      return b.getBounds();
    }
  }

  void build(SIBuilder<String, SIImageData> builder) {
    RectT userSpace() => userSpaceBounds;
    final rootPaint = SvgPaint.initial(userSpace);
    final rootTA = SvgTextAttributes.initial();
    SvgNode? newRoot =
        root.resolve(idLookup, rootPaint, builder.warn, _Referrers(this));
    _resolved = true;
    builder.vector(
        width: width, height: height, tintColor: tintColor, tintMode: tintMode);

    // Collect canonicalized data by doing a build dry run.  We skip of the
    // paths and other stuff that doesn't generate canonicalized data, so
    // this is quite fast.
    final theCanon = CanonicalizedData<SIImageData>();
    newRoot?.build(
        _CollectCanonBuilder(theCanon), theCanon, idLookup, rootPaint, rootTA);

    // Now we can do the real building run.
    builder.init(
        null,
        theCanon.images.toList(),
        theCanon.strings.toList(),
        theCanon.floatLists.toList(),
        theCanon.floatValues.toList(),
        theCanon.floatValues);
    newRoot?.build(builder, theCanon, idLookup, rootPaint, rootTA);
    builder.endVector();
  }
}

class _CollectCanonBuilder implements SIBuilder<String, SIImageData> {
  final CanonicalizedData canon;
  late final colorWriter = ColorWriter(
      DataOutputSink(_NullSink()), (_) => null, _collectSharedFloat);

  _CollectCanonBuilder(this.canon);

  void collectPaint(SIPaint paint) {
    colorWriter.writeColor(paint.fillColor);
    colorWriter.writeColor(paint.strokeColor);
  }

  void _collectSharedFloat(double value) => canon.floatValues[value];

  @override
  void init(
      void collector,
      List<SIImageData> im,
      List<String> strings,
      List<List<double>> floatLists,
      List<double> floatValues,
      CMap<double>? floatValueMap) {}

  @override
  void vector(
      {required double? width,
      required double? height,
      required int? tintColor,
      required SITintMode? tintMode}) {}

  @override
  void endVector() {}

  @override
  void group(
      void collector, Affine? transform, int? groupAlpha, SIBlendMode blend) {}

  @override
  void endGroup(void collector) {}

  @override
  void path(void collector, String pathData, SIPaint paint) =>
      collectPaint(paint);

  @override
  PathBuilder? startPath(SIPaint paint, Object key) {
    collectPaint(paint);
    return null;
  }

  @override
  void clipPath(void collector, String pathData) {}

  @override
  void masked(void collector, RectT? maskBounds, bool usesLuma) {}

  @override
  void maskedChild(void collector) {}

  @override
  void endMasked(void collector) {}

  @override
  void image(void collector, int imageIndex) {}

  @override
  void legacyText(void collector, int xIndex, int yIndex, int textIndex,
      SITextAttributes a, int? fontFamilyIndex, SIPaint paint) {
    // No collectAttributes() because the legacy format doesn't use
    // canonicalized data for that.
    collectPaint(paint);
  }

  @override
  void text(void collector) {}

  @override
  void textMultiSpanChunk(
      void collector, int dxIndex, int dyIndex, SITextAnchor anchor) {}

  @override
  void textSpan(
      void collector,
      int dxIndex,
      int dyIndex,
      int textIndex,
      SITextAttributes attributes,
      int? fontFamilyIndex,
      int fontSizeIndex,
      SIPaint paint) {
    collectPaint(paint);
  }

  @override
  void textEnd(void collector) {}

  @override
  void printWarning(String warning) {}

  @override
  void assertDone() {}

  @override
  void get initial {}

  @override
  bool get warn => false;
}

/// An entry in the list of styles for a given element type in the
/// stylesheet.
class Style extends SvgInheritableAttributes {
  Style(String styleClass) : super(styleClass: styleClass);

  set styleClass(String v) {
    // Do nothing:  Unlike a node, our styleClass doesn't come from the
    // parser.  A badly formed CSS entry could try to set an attribute
    // called 'class,' so we ignore any such attempts.
  }

  void applyText(SvgInheritableTextAttributes node) {
    node.paint.takeFrom(this);
    node.textAttributes.takeFrom(this);
  }

  void apply(SvgInheritableAttributes node) {
    applyText(node);
    node.transform = node.transform ?? transform;
    node.blendMode = node.blendMode ?? blendMode;
  }

  @override
  String get tagName => 'style'; // Not used
}

typedef Stylesheet = Map<String, List<Style>>;

abstract class SvgNode {
  void applyStylesheet(Stylesheet stylesheet);

  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers);

  bool build(
      SIBuilder<String, SIImageData> builder,
      CanonicalizedData<SIImageData> canon,
      Map<String, SvgNode> idLookup,
      SvgPaint ancestor,
      SvgTextAttributes ta,
      {bool blendHandledByParent = false});

  ///
  /// If this node is in a mask, is it possible it might use the luma
  /// channel?  cf. SIMaskHelper.startLumaMask().
  ///
  bool canUseLuma(Map<String, SvgNode> idLookup, SvgPaint ancestor,
      void Function(String) warn);

  SIBlendMode? get blendMode;

  _SvgBoundary? _getUserSpaceBoundary(SvgTextAttributes ta);
}

class _NullSink<T> implements Sink<T> {
  @override
  void add(T data) {}

  @override
  void close() {}
}

///
/// Things that refer to a node, like a group.
/// This is used to catch reference loops.
///
class _Referrers {
  final Object? referrer;
  final _Referrers? parent;

  _Referrers(this.referrer, [this.parent]);

  bool contains(SvgNode n) {
    _Referrers? s = this;
    while (s != null) {
      if (identical(s.referrer, n)) {
        return true;
      }
      s = s.parent;
    }
    return false;
  }
}

/// Just the inheritable attributes that are applicable to text
abstract class SvgInheritableTextAttributes {
  final SvgPaint paint;
  SvgTextAttributes textAttributes = SvgTextAttributes.empty();
  String styleClass; // Doesn't inherit.
  String get tagName;

  SvgInheritableTextAttributes({SvgPaint? paint, this.styleClass = ''})
      : paint = paint ?? SvgPaint.empty();

  bool _isInvisible(SvgPaint cascaded) {
    return cascaded.hidden == true ||
        ((cascaded.strokeAlpha == 0 || cascaded.strokeColor == SvgColor.none) &&
            (cascaded.fillAlpha == 0 || cascaded.fillColor == SvgColor.none) &&
            !cascaded.inClipPath);
  }

  static final _whitespace = RegExp(r'\s+');
  void applyStylesheet(Stylesheet stylesheet) {
    final ourClasses = styleClass.trim().split(_whitespace).toSet();
    if (ourClasses.isNotEmpty) {
      for (final tag in [tagName, '']) {
        final List<Style>? styles = stylesheet[tag];
        if (styles != null) {
          for (int i = styles.length - 1; i >= 0; i--) {
            final s = styles[i];
            if (ourClasses.contains(s.styleClass)) {
              _takeFrom(s);
            }
          }
        }
      }
    }
    final List<Style>? styles = stylesheet[tagName];
    if (styles != null) {
      for (int i = styles.length - 1; i >= 0; i--) {
        final s = styles[i];
        if (s.styleClass == '') {
          _takeFrom(s);
        }
      }
    }
  }

  @protected
  void _takeFrom(Style s) {
    s.applyText(this);
  }
}

abstract class SvgInheritableAttributes extends SvgInheritableTextAttributes {
  MutableAffine? transform;
  bool display = true;
  int? groupAlpha; // Doesn't inherit; instead, a group is created
  SIBlendMode? blendMode;
  // Doesn't inherit; instead, a group is created

  SvgInheritableAttributes({SvgPaint? paint, String styleClass = ''})
      : super(paint: paint, styleClass: styleClass);

  @override
  void _takeFrom(Style s) {
    s.apply(this);
  }
}

abstract class SvgInheritableAttributesNode extends SvgInheritableAttributes
    implements SvgNode {
  SvgInheritableAttributesNode({SvgPaint? paint}) : super(paint: paint);

  @override
  bool _isInvisible(SvgPaint cascaded) =>
      !display || super._isInvisible(cascaded);

  bool _hasNonMaskAttributes() =>
      transform != null ||
      paint != SvgPaint.empty() ||
      textAttributes != SvgTextAttributes.empty() ||
      groupAlpha != null ||
      blendMode != SIBlendMode.normal;

  @override
  _SvgBoundary? _getUserSpaceBoundary(SvgTextAttributes ta) {
    RectT? bounds = _getUntransformedBounds(ta);
    if (bounds == null) {
      return null;
    } else {
      final b = _SvgBoundary(bounds);
      final t = transform;
      if (t == null) {
        return b;
      } else {
        return b.transformed(t);
      }
    }
  }

  @protected
  RectT? _getUntransformedBounds(SvgTextAttributes ta);

  SvgNode resolveMask(Map<String, SvgNode> idLookup, SvgPaint ancestor,
      bool warn, _Referrers referrers) {
    if (paint.mask != null) {
      SvgNode? n = idLookup[paint.mask];
      if (n is SvgMask) {
        if (referrers.contains(n)) {
          if (warn) {
            print('    Ignoring mask that refers to itself.');
          }
        } else {
          final masked = SvgMasked(this, n);
          if (_hasNonMaskAttributes()) {
            final g = SvgGroup();
            g.transform = transform;
            transform = null;
            g.textAttributes = textAttributes;
            textAttributes = SvgTextAttributes.empty();
            g.groupAlpha = groupAlpha;
            groupAlpha = null;
            g.blendMode = blendMode;
            blendMode = SIBlendMode.normal;
            g.children.add(masked);
            return g;
          } else {
            return masked;
          }
        }
      } else if (warn) {
        print('    $this references nonexistent mask ${paint.mask}');
      }
    }
    return this;
  }
}

class SvgPaint {
  SvgColor currentColor;
  SvgColor fillColor;
  int? fillAlpha;
  SvgColor strokeColor;
  int? strokeAlpha;
  double? strokeWidth;
  double? strokeMiterLimit;
  SIStrokeJoin? strokeJoin;
  SIStrokeCap? strokeCap;
  SIFillType? fillType;
  SIFillType? clipFillType;
  bool inClipPath;
  List<double>? strokeDashArray; // [] for "none"
  double? strokeDashOffset;
  bool? hidden;
  String? mask; // Not inherited
  final RectT Function() userSpace; // only inherited (from root)

  SvgPaint(
      {required this.currentColor,
      required this.fillColor,
      required this.fillAlpha,
      required this.strokeColor,
      required this.strokeAlpha,
      required this.strokeWidth,
      required this.strokeMiterLimit,
      required this.strokeJoin,
      required this.strokeCap,
      required this.fillType,
      required this.clipFillType,
      required this.inClipPath,
      required this.strokeDashArray,
      required this.strokeDashOffset,
      required this.hidden,
      required this.mask,
      required this.userSpace});

  SvgPaint.empty()
      : fillColor = SvgColor.inherit,
        strokeColor = SvgColor.inherit,
        currentColor = SvgColor.inherit,
        inClipPath = false,
        userSpace = _dummy;

  static RectT _dummy() => const RectT(0, 0, 0, 0);

  factory SvgPaint.initial(
    RectT Function() userSpace,
  ) =>
      SvgPaint(
          currentColor: SvgColor.currentColor, // Inherit from SVG container
          fillColor: const SvgValueColor(0xff000000),
          fillAlpha: 0xff,
          strokeColor: SvgColor.none,
          strokeAlpha: 0xff,
          strokeWidth: 1,
          strokeMiterLimit: 4,
          strokeJoin: SIStrokeJoin.miter,
          strokeCap: SIStrokeCap.butt,
          fillType: SIFillType.nonZero,
          clipFillType: SIFillType.nonZero,
          inClipPath: false,
          strokeDashArray: null,
          strokeDashOffset: null,
          hidden: false,
          mask: null,
          userSpace: userSpace);

  SvgPaint cascade(SvgPaint ancestor, Map<String, SvgNode>? idLookup) {
    return SvgPaint(
        currentColor: currentColor.orInherit(ancestor.currentColor, idLookup),
        fillColor: fillColor.orInherit(ancestor.fillColor, idLookup),
        fillAlpha: fillAlpha ?? ancestor.fillAlpha,
        strokeColor: strokeColor.orInherit(ancestor.strokeColor, idLookup),
        strokeAlpha: strokeAlpha ?? ancestor.strokeAlpha,
        strokeWidth: strokeWidth ?? ancestor.strokeWidth,
        strokeMiterLimit: strokeMiterLimit ?? ancestor.strokeMiterLimit,
        strokeJoin: strokeJoin ?? ancestor.strokeJoin,
        strokeCap: strokeCap ?? ancestor.strokeCap,
        fillType: fillType ?? ancestor.fillType,
        clipFillType: clipFillType ?? ancestor.clipFillType,
        inClipPath: inClipPath || ancestor.inClipPath,
        strokeDashArray: strokeDashArray ?? ancestor.strokeDashArray,
        strokeDashOffset: strokeDashOffset ?? ancestor.strokeDashOffset,
        mask: null, // Mask is not inherited
        hidden: hidden ?? ancestor.hidden,
        userSpace: ancestor.userSpace); // userSpace is inherited from root
  }

  void takeFrom(Style style) {
    currentColor = currentColor.orInherit(style.paint.currentColor, null);
    fillColor = fillColor.orInherit(style.paint.fillColor, null);
    fillAlpha = fillAlpha ?? style.paint.fillAlpha;
    strokeColor = strokeColor.orInherit(style.paint.strokeColor, null);
    strokeAlpha = strokeAlpha ?? style.paint.strokeAlpha;
    strokeWidth = strokeWidth ?? style.paint.strokeWidth;
    strokeMiterLimit = strokeMiterLimit ?? style.paint.strokeMiterLimit;
    strokeJoin = strokeJoin ?? style.paint.strokeJoin;
    strokeCap = strokeCap ?? style.paint.strokeCap;
    fillType = fillType ?? style.paint.fillType;
    clipFillType = clipFillType ?? style.paint.clipFillType;
    inClipPath = inClipPath || style.paint.inClipPath;
    strokeDashArray = strokeDashArray ?? style.paint.strokeDashArray;
    strokeDashOffset = strokeDashOffset ?? style.paint.strokeDashOffset;
    hidden = hidden ?? style.paint.hidden;
  }

  @override
  int get hashCode =>
      0x5390dc64 ^
      Object.hash(
          fillColor,
          fillAlpha,
          strokeColor,
          strokeAlpha,
          strokeWidth,
          strokeMiterLimit,
          currentColor,
          hidden,
          mask,
          strokeJoin,
          strokeCap,
          fillType,
          clipFillType,
          inClipPath,
          strokeDashOffset,
          Object.hashAll(strokeDashArray ?? const []));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    } else if (other is SvgPaint) {
      return currentColor == other.currentColor &&
          fillColor == other.fillColor &&
          fillAlpha == other.fillAlpha &&
          strokeColor == other.strokeColor &&
          strokeAlpha == other.strokeAlpha &&
          strokeWidth == other.strokeWidth &&
          strokeMiterLimit == other.strokeMiterLimit &&
          currentColor == other.currentColor &&
          mask == other.mask &&
          hidden == other.hidden &&
          strokeJoin == other.strokeJoin &&
          strokeCap == other.strokeCap &&
          fillType == other.fillType &&
          clipFillType == other.clipFillType &&
          inClipPath == other.inClipPath &&
          quiver.listsEqual(strokeDashArray, other.strokeDashArray) &&
          strokeDashOffset == other.strokeDashOffset;
    } else {
      return false;
    }
  }

  SIPaint toSIPaint(void Function(String) warn) {
    if (hidden == true) {
      // Hidden nodes should be optimized away
      assert(hidden != true);
      return SIPaint(
          fillColor: SIColor.none,
          strokeColor: SIColor.none,
          strokeWidth: 0,
          strokeMiterLimit: 4,
          strokeJoin: SIStrokeJoin.miter,
          strokeCap: SIStrokeCap.butt,
          fillType: clipFillType,
          strokeDashArray: null,
          strokeDashOffset: null);
    } else if (inClipPath) {
      // See SVG 1.1, s. 14.3.5
      return SIPaint(
          fillColor: SIColor.white,
          strokeColor: SIColor.none,
          strokeWidth: 0,
          strokeMiterLimit: 4,
          strokeJoin: SIStrokeJoin.miter,
          strokeCap: SIStrokeCap.butt,
          fillType: clipFillType,
          strokeDashArray: null,
          strokeDashOffset: null);
    } else {
      return SIPaint(
          fillColor: fillColor.toSIColor(fillAlpha, currentColor, userSpace),
          strokeColor:
              strokeColor.toSIColor(strokeAlpha, currentColor, userSpace),
          strokeWidth: strokeWidth,
          strokeMiterLimit: strokeMiterLimit,
          strokeJoin: strokeJoin,
          strokeCap: strokeCap,
          fillType: fillType,
          strokeDashArray: strokeDashArray,
          strokeDashOffset: strokeDashArray == null ? null : strokeDashOffset);
    }
  }
}

class SvgGroup extends SvgInheritableAttributesNode {
  var children = List<SvgNode>.empty(growable: true);
  @protected
  bool get multipleNodesOK => false;

  SvgGroup({SvgPaint? paint}) : super(paint: paint);

  @override
  String get tagName => 'g';

  @override
  void applyStylesheet(Stylesheet stylesheet) {
    super.applyStylesheet(stylesheet);
    for (final c in children) {
      c.applyStylesheet(stylesheet);
    }
  }

  @override
  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    final cascaded = paint.cascade(ancestor, idLookup);
    final newC = List<SvgNode>.empty(growable: true);
    referrers = _Referrers(this, referrers);
    for (SvgNode n in children) {
      final nn = n.resolve(idLookup, cascaded, warn, referrers);
      if (nn != null) {
        newC.add(nn);
      }
    }
    children = newC;
    if (children.isEmpty) {
      return null;
    } else if (transform?.determinant() == 0.0) {
      return null;
    } else {
      return resolveMask(idLookup, ancestor, warn, referrers);
    }
  }

  @override
  RectT? _getUntransformedBounds(SvgTextAttributes ta) {
    final currTA = textAttributes.cascade(ta);
    RectT? curr;
    for (final ch in children) {
      final boundary = ch._getUserSpaceBoundary(currTA);
      if (boundary != null) {
        final b = boundary.getBounds();
        if (curr == null) {
          curr = b;
        } else {
          curr = curr.boundingBox(b);
        }
      }
    }
    return curr;
  }

  @override
  bool build(
      SIBuilder<String, SIImageData> builder,
      CanonicalizedData<SIImageData> canon,
      Map<String, SvgNode> idLookup,
      SvgPaint ancestor,
      SvgTextAttributes ta,
      {bool blendHandledByParent = false}) {
    if (!display) {
      return false;
    }
    final blend = blendHandledByParent
        ? SIBlendMode.normal
        : (blendMode ?? SIBlendMode.normal);
    final currTA = textAttributes.cascade(ta);
    final cascaded = paint.cascade(ancestor, idLookup);
    if (transform == null &&
        groupAlpha == null &&
        blend == SIBlendMode.normal &&
        (children.length == 1 || multipleNodesOK)) {
      bool r = false;
      for (final c in children) {
        r = c.build(builder, canon, idLookup, cascaded, currTA) || r;
      }
      return r;
    } else {
      builder.group(null, transform, groupAlpha, blend);
      for (final c in children) {
        c.build(builder, canon, idLookup, cascaded, currTA);
      }
      builder.endGroup(null);
      return true;
    }
  }

  @override
  bool canUseLuma(Map<String, SvgNode> idLookup, SvgPaint ancestor,
      void Function(String) warn) {
    final cascaded = paint.cascade(ancestor, idLookup);
    for (final ch in children) {
      if (ch.canUseLuma(idLookup, cascaded, warn)) {
        return true;
      }
    }
    return false;
  }
}

class SvgRoot extends SvgGroup {
  @override
  bool get multipleNodesOK => true;

  @override
  String get tagName => 'svg';
}

class SvgDefs extends SvgGroup {
  @override
  final String tagName;

  SvgDefs(this.tagName) : super();

  @override
  SvgGroup? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    super.resolve(idLookup, ancestor, warn, referrers);
    return null;
  }

  @override
  bool build(SIBuilder<String, SIImageData> builder, CanonicalizedData canon,
      Map<String, SvgNode> idLookup, SvgPaint ancestor, SvgTextAttributes ta,
      {bool blendHandledByParent = false}) {
    assert(false);
    return false;
  }

  @override
  RectT? _getUntransformedBounds(SvgTextAttributes ta) => null;
}

///
/// The mask itself, from a <mask> tag in the source file
///
class SvgMask extends SvgGroup {
  RectT? bufferBounds;

  @override
  SvgGroup? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    if (referrers.contains(this)) {
      if (warn) {
        print('    Ignoring mask contained by itself.');
      }
      return null;
    } else {
      super.resolve(idLookup, ancestor, warn, _Referrers(this, referrers));
      return null;
    }
  }
}

///
/// A parent node for a node with a mask attribute.
///
class SvgMasked extends SvgNode {
  final SvgNode child;
  SvgMask mask;

  SvgMasked(this.child, this.mask);

  @override
  void applyStylesheet(Stylesheet stylesheet) {
    assert(false);
    // Do nothing - stylesheets are applied before Masked are created.
  }

  @override
  _SvgBoundary? _getUserSpaceBoundary(SvgTextAttributes ta) {
    final m = mask._getUserSpaceBoundary(ta);
    if (m == null) {
      return m;
    }
    final c = child._getUserSpaceBoundary(ta);
    if (c == null) {
      return c;
    }
    final i = c.getBounds().intersection(m.getBounds());
    if (i == null) {
      return null;
    } else {
      return _SvgBoundary(i);
    }
  }

  @override
  bool build(
      SIBuilder<String, SIImageData> builder,
      CanonicalizedData<SIImageData> canon,
      Map<String, SvgNode> idLookup,
      SvgPaint ancestor,
      SvgTextAttributes ta,
      {bool blendHandledByParent = false}) {
    final blend = blendHandledByParent
        ? SIBlendMode.normal
        : (blendMode ?? SIBlendMode.normal);
    if (blend != SIBlendMode.normal) {
      builder.group(null, null, null, blend);
    }

    bool canUseLuma = mask.canUseLuma(idLookup, ancestor, builder.printWarning);
    builder.masked(null, mask.bufferBounds, canUseLuma);
    bool built = mask.build(builder, canon, idLookup, ancestor, ta);
    if (!built) {
      builder.group(null, null, null, SIBlendMode.normal);
      builder.endGroup(null);
    }
    builder.maskedChild(null);
    built = child.build(builder, canon, idLookup, ancestor, ta,
        blendHandledByParent: true);
    if (!built) {
      builder.group(null, null, null, SIBlendMode.normal);
      builder.endGroup(null);
    }
    builder.endMasked(null);
    if (blend != SIBlendMode.normal) {
      builder.endGroup(null);
    }
    return true;
  }

  @override
  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    assert(false); // We're added during resolve
    return null;
  }

  @override
  bool canUseLuma(Map<String, SvgNode> idLookup, SvgPaint ancestor,
          void Function(String) warn) =>
      child.canUseLuma(idLookup, ancestor, warn);
  // The mask can only change the alpha channel.

  @override
  SIBlendMode? get blendMode => child.blendMode;
}

class SvgUse extends SvgInheritableAttributesNode {
  String? childID;

  SvgUse(this.childID);

  @override
  String get tagName => 'use';

  @override
  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    if (childID == null) {
      if (warn) {
        print('    <use> has no xlink:href');
      }
      return null;
    }
    SvgNode? n = idLookup[childID];
    if (n == null) {
      if (warn) {
        print('    <use> references nonexistent $childID');
      }
      return null;
    } else if (referrers.contains(n)) {
      if (warn) {
        print('    Ignoring <use> that refers to itself.');
      }
      return null;
    }
    final cascaded = paint.cascade(ancestor, idLookup);
    n = n.resolve(idLookup, cascaded, warn, referrers);
    if (n == null || transform?.determinant() == 0.0) {
      return null;
    }
    final g = SvgGroup(paint: paint);
    g.groupAlpha = groupAlpha;
    g.transform = transform;
    g.children.add(n);
    return g.resolveMask(idLookup, ancestor, warn, referrers);
  }

  @override
  RectT? _getUntransformedBounds(SvgTextAttributes ta) {
    assert(false);
    return null;
  }

  @override
  bool build(SIBuilder<String, SIImageData> builder, CanonicalizedData canon,
      Map<String, SvgNode> idLookup, SvgPaint ancestor, SvgTextAttributes ta,
      {bool blendHandledByParent = false}) {
    assert(false);
    return false;
  }

  @override
  bool canUseLuma(Map<String, SvgNode> idLookup, SvgPaint ancestor,
      void Function(String) warn) {
    assert(false); // Should be called after resolve
    return true;
  }
}

abstract class SvgPathMaker extends SvgInheritableAttributesNode {
  @override
  bool build(SIBuilder<String, SIImageData> builder, CanonicalizedData canon,
      Map<String, SvgNode> idLookup, SvgPaint ancestor, SvgTextAttributes ta,
      {bool blendHandledByParent = false}) {
    if (!display) {
      return false;
    }
    final blend = blendHandledByParent
        ? SIBlendMode.normal
        : (blendMode ?? SIBlendMode.normal);
    final cascaded = paint.cascade(ancestor, idLookup);
    if (cascaded.hidden == true) {
      return false;
    } else if (transform != null ||
        groupAlpha != null ||
        blend != SIBlendMode.normal) {
      builder.group(null, transform, groupAlpha, blend);
      makePath(builder, cascaded);
      builder.endGroup(null);
      return true;
    } else {
      return makePath(builder, cascaded);
    }
  }

  /// Returns true if a path node is emitted
  bool makePath(SIBuilder<String, SIImageData> builder, SvgPaint cascaded);

  @override
  bool canUseLuma(Map<String, SvgNode> idLookup, SvgPaint ancestor,
      void Function(String) warn) {
    final cascaded = paint.cascade(ancestor, idLookup);
    final p = cascaded.toSIPaint(warn);
    return p.canUseLuma;
  }
}

class SvgPath extends SvgPathMaker {
  final String pathData;

  SvgPath(this.pathData);

  @override
  String get tagName => 'path';

  @override
  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    if (pathData == '') {
      return null;
    } else {
      return resolveMask(idLookup, ancestor, warn, referrers);
    }
  }

  @override
  RectT? _getUntransformedBounds(SvgTextAttributes ta) {
    if (pathData == '') {
      return null;
    }
    final builder = _SvgPathBoundsBuilder();
    PathParser(builder, pathData).parse();
    return builder.bounds;
  }

  @override
  bool makePath(SIBuilder<String, SIImageData> builder, SvgPaint cascaded) {
    if (_isInvisible(cascaded)) {
      return false;
    } else {
      builder.path(null, pathData, cascaded.toSIPaint(builder.printWarning));
      return true;
    }
  }
}

class _SvgPathBoundsBuilder implements PathBuilder {
  RectT? bounds;

  @override
  void addOval(RectT rect) {
    final b = bounds;
    if (b == null) {
      bounds = rect;
    } else {
      bounds = b.boundingBox(rect);
    }
  }

  @override
  void arcToPoint(PointT arcEnd,
      {required RadiusT radius,
      required double rotation,
      required bool largeArc,
      required bool clockwise}) {
    final b = bounds;
    final rect = RectT.fromPoints(arcEnd, arcEnd);
    if (b == null) {
      bounds = rect;
    } else {
      bounds = b.boundingBox(rect);
    }
  }

  @override
  void close() {}

  @override
  void cubicTo(PointT c1, PointT c2, PointT p, bool shorthand) {
    final b = bounds;
    final rect = RectT.fromPoints(c1, c2).boundingBox(RectT.fromPoints(p, p));
    if (b == null) {
      bounds = rect;
    } else {
      bounds = b.boundingBox(rect);
    }
  }

  @override
  void end() {}

  @override
  void lineTo(PointT p) {
    final b = bounds;
    final rect = RectT.fromPoints(p, p);
    if (b == null) {
      bounds = rect;
    } else {
      bounds = b.boundingBox(rect);
    }
  }

  @override
  void moveTo(PointT p) {
    final b = bounds;
    final rect = RectT.fromPoints(p, p);
    if (b == null) {
      bounds = rect;
    } else {
      bounds = b.boundingBox(rect);
    }
  }

  @override
  void quadraticBezierTo(PointT control, PointT p, bool shorthand) {
    final b = bounds;
    final rect = RectT.fromPoints(control, p);
    if (b == null) {
      bounds = rect;
    } else {
      bounds = b.boundingBox(rect);
    }
  }
}

class SvgRect extends SvgPathMaker {
  final double x;
  final double y;
  final double width;
  final double height;
  final double rx;
  final double ry;

  SvgRect(this.x, this.y, this.width, this.height, this.rx, this.ry);

  @override
  String get tagName => 'rect';

  @override
  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    if (width <= 0 || height <= 0) {
      return null;
    } else {
      return resolveMask(idLookup, ancestor, warn, referrers);
    }
  }

  @override
  RectT? _getUntransformedBounds(SvgTextAttributes ta) =>
      Rectangle(x, y, width, height);

  @override
  bool makePath(SIBuilder<String, SIImageData> builder, SvgPaint cascaded) {
    if (_isInvisible(cascaded)) {
      return false;
    }
    SIPaint curr = cascaded.toSIPaint(builder.printWarning);
    PathBuilder? pb = builder.startPath(curr, this);
    if (pb == null) {
      return true;
    }
    if (rx <= 0 || ry <= 0) {
      pb.moveTo(PointT(x, y));
      pb.lineTo(PointT(x + width, y));
      pb.lineTo(PointT(x + width, y + height));
      pb.lineTo(PointT(x, y + height));
      pb.close();
    } else {
      final r = RadiusT(rx, ry);
      pb.moveTo(PointT(x + rx, y));
      pb.lineTo(PointT(x + width - rx, y));
      pb.arcToPoint(PointT(x + width, y + ry),
          radius: r, rotation: 0, largeArc: false, clockwise: true);
      pb.lineTo(PointT(x + width, y + height - ry));
      pb.arcToPoint(PointT(x + width - rx, y + height),
          radius: r, rotation: 0, largeArc: false, clockwise: true);
      pb.lineTo(PointT(x + rx, y + height));
      pb.arcToPoint(PointT(x, y + height - ry),
          radius: r, rotation: 0, largeArc: false, clockwise: true);
      pb.lineTo(PointT(x, y + ry));
      pb.arcToPoint(PointT(x + rx, y),
          radius: r, rotation: 0, largeArc: false, clockwise: true);
      pb.close();
    }
    pb.end();
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    } else if (other is SvgRect) {
      return x == other.x &&
          y == other.y &&
          width == other.width &&
          height == other.height &&
          rx == other.rx &&
          ry == other.ry &&
          display == other.display;
    } else {
      return false;
    }
  }

  @override
  int get hashCode =>
      0x04acdf77 ^ Object.hash(x, y, width, height, rx, ry, display);
}

class SvgEllipse extends SvgPathMaker {
  final double cx;
  final double cy;
  final double rx;
  final double ry;
  @override
  final String tagName;

  SvgEllipse(this.tagName, this.cx, this.cy, this.rx, this.ry);

  @override
  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    if (rx <= 0 || ry <= 0) {
      return null;
    } else {
      return resolveMask(idLookup, ancestor, warn, referrers);
    }
  }

  @override
  RectT? _getUntransformedBounds(SvgTextAttributes ta) =>
      Rectangle(cx - rx, cy - ry, 2 * rx, 2 * ry);

  @override
  bool makePath(SIBuilder<String, SIImageData> builder, SvgPaint cascaded) {
    if (_isInvisible(cascaded)) {
      return false;
    }
    SIPaint curr = cascaded.toSIPaint(builder.printWarning);
    PathBuilder? pb = builder.startPath(curr, this);
    if (pb == null) {
      return true;
    }
    pb.addOval(RectT(cx - rx, cy - ry, 2 * rx, 2 * ry));
    pb.end();
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    } else if (other is SvgEllipse) {
      return cx == other.cx &&
          cy == other.cy &&
          rx == other.rx &&
          ry == other.ry &&
          display == other.display;
    } else {
      return false;
    }
  }

  @override
  int get hashCode => 0x795d8ece ^ Object.hash(cx, cy, rx, ry, display);
}

class SvgPoly extends SvgPathMaker {
  final bool close; // true makes it a polygon; false a polyline
  final List<Point<double>> points;
  @override
  final String tagName;

  SvgPoly(this.tagName, this.close, this.points);

  @override
  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    if (points.length < 2) {
      return null;
    } else {
      return resolveMask(idLookup, ancestor, warn, referrers);
    }
  }

  @override
  RectT? _getUntransformedBounds(SvgTextAttributes ta) {
    RectT? curr;
    for (final p in points) {
      if (curr == null) {
        curr = Rectangle.fromPoints(p, p);
      } else if (!curr.containsPoint(p)) {
        curr = curr.boundingBox(Rectangle.fromPoints(p, p));
      }
    }
    return curr;
  }

  @override
  bool makePath(SIBuilder<String, SIImageData> builder, SvgPaint cascaded) {
    if (_isInvisible(cascaded)) {
      return false;
    }
    SIPaint curr = cascaded.toSIPaint(builder.printWarning);
    PathBuilder? pb = builder.startPath(curr, this);
    if (pb == null) {
      return true;
    }
    pb.moveTo(points[0]);
    for (int i = 1; i < points.length; i++) {
      pb.lineTo(points[i]);
    }
    if (close) {
      pb.close();
    }
    pb.end();
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    } else if (other is SvgPoly) {
      return close == other.close &&
          display == other.display &&
          quiver.listsEqual(points, other.points);
    } else {
      return false;
    }
  }

  @override
  int get hashCode =>
      0xf4e007c0 ^ Object.hash(display, close, Object.hashAll(points));
}

class SvgGradientNode implements SvgNode {
  final SvgGradientColor gradient;
  final String? parentID;

  SvgGradientNode(this.parentID, this.gradient);

  @override
  void applyStylesheet(Stylesheet stylesheet) {}

  @override
  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    final pid = parentID;
    if (pid != null) {
      var parent = idLookup[pid];
      var pLoop = parent;
      while (pLoop is SvgGradientNode) {
        if (identical(pLoop, this)) {
          if (warn) {
            print('    Gradient references itself:  $pid');
          }
          pLoop = null;
          parent = null;
        } else {
          final ppid = pLoop.parentID;
          if (ppid == null) {
            pLoop = null;
          } else {
            pLoop = idLookup[ppid];
          }
        }
      }
      if (parent is SvgGradientNode) {
        gradient.parent = parent.gradient;
      } else {
        if (warn) {
          print('    Gradient references non-existent gradient $pid');
        }
      }
    }
    // Our underlying gradient gets incorporated into SIPaint, so no reason to
    // keep the node around
    return null;
  }

  @override
  _SvgBoundary? _getUserSpaceBoundary(SvgTextAttributes ta) => null;

  @override
  bool build(SIBuilder<String, SIImageData> builder, CanonicalizedData canon,
      Map<String, SvgNode> idLookup, SvgPaint ancestor, SvgTextAttributes ta,
      {bool blendHandledByParent = false}) {
    // Do nothing - gradients are included in SIPaint
    return false;
  }

  @override
  bool canUseLuma(Map<String, SvgNode> idLookup, SvgPaint ancestor,
      void Function(String) warn) {
    return false; // Because this node doesn't directly do any rendering
  }

  /// Meaningless for us
  @override
  SIBlendMode get blendMode => SIBlendMode.normal;
}

class SvgImage extends SvgInheritableAttributesNode {
  Uint8List imageData = _emptyData;
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;

  SvgImage();

  @override
  String get tagName => 'image';

  static final Uint8List _emptyData = Uint8List(0);

  @override
  SvgNode? resolve(Map<String, SvgNode> idLookup, SvgPaint ancestor, bool warn,
      _Referrers referrers) {
    if (width <= 0 || height <= 0) {
      return null;
    }
    return resolveMask(idLookup, ancestor, warn, referrers);
  }

  @override
  RectT? _getUntransformedBounds(SvgTextAttributes ta) =>
      Rectangle(x, y, width, height);

  @override
  bool build(
      SIBuilder<String, SIImageData> builder,
      CanonicalizedData<SIImageData> canon,
      Map<String, SvgNode> idLookup,
      SvgPaint ancestor,
      SvgTextAttributes ta,
      {bool blendHandledByParent = false}) {
    if (!display) {
      return false;
    }
    final blend = blendHandledByParent
        ? SIBlendMode.normal
        : (blendMode ?? SIBlendMode.normal);
    final sid = SIImageData(
        x: x, y: y, width: width, height: height, encoded: imageData);
    int imageNumber = canon.images[sid];
    final cascaded = paint.cascade(ancestor, idLookup);
    if (cascaded.hidden == true) {
      return false;
    } else if (transform != null ||
        groupAlpha != null ||
        blend != SIBlendMode.normal) {
      builder.group(null, transform, groupAlpha, blend);
      builder.image(null, imageNumber);
      builder.endGroup(null);
    } else {
      builder.image(null, imageNumber);
    }
    return true;
  }

  @override
  bool canUseLuma(Map<String, SvgNode> idLookup, SvgPaint ancestor,
      void Function(String) warn) {
    return true;
  }
}

abstract class SvgTextNodeAttributes extends SvgInheritableTextAttributes {
  List<double>? get x;
  List<double>? get y;
  List<double>? dx;
  List<double>? dy;
}

class SvgTextAttributes {
  String? fontFamily;
  SIFontStyle? fontStyle;
  SITextAnchor? textAnchor;
  SITextDecoration? textDecoration;
  SvgFontWeight fontWeight = SvgFontWeight.inherit;
  SvgFontSize fontSize = SvgFontSize.inherit;

  SvgTextAttributes.empty();
  SvgTextAttributes(
      {required this.fontFamily,
      required this.fontStyle,
      required this.textAnchor,
      required this.fontWeight,
      required this.fontSize,
      required this.textDecoration});

  SvgTextAttributes.initial()
      : fontFamily = '',
        textAnchor = SITextAnchor.start,
        fontStyle = SIFontStyle.normal,
        fontWeight = SvgFontWeight.w400,
        fontSize = SvgFontSize.medium,
        textDecoration = SITextDecoration.none;

  SvgTextAttributes cascade(SvgTextAttributes ancestor) {
    return SvgTextAttributes(
        fontSize: fontSize.orInherit(ancestor.fontSize),
        fontFamily: fontFamily ?? ancestor.fontFamily,
        textAnchor: textAnchor ?? ancestor.textAnchor,
        textDecoration: textDecoration ?? ancestor.textDecoration,
        fontWeight: fontWeight.orInherit(ancestor.fontWeight),
        fontStyle: fontStyle ?? ancestor.fontStyle);
  }

  void takeFrom(Style style) {
    fontSize = fontSize.orInherit(style.textAttributes.fontSize);
    fontFamily = fontFamily ?? style.textAttributes.fontFamily;
    textAnchor = textAnchor ?? style.textAttributes.textAnchor;
    textDecoration = textDecoration ?? style.textAttributes.textDecoration;
    fontWeight = fontWeight.orInherit(style.textAttributes.fontWeight);
    fontStyle = fontStyle ?? style.textAttributes.fontStyle;
  }

  SITextAttributes toSITextAttributes() => SITextAttributes(
      fontFamily: fontFamily!,
      textAnchor: textAnchor!,
      textDecoration: textDecoration!,
      fontStyle: fontStyle!,
      fontWeight: fontWeight.toSI(),
      fontSize: fontSize.toSI());
}

///
/// Font size as SVG knows it.
///
abstract class SvgFontSize {
  const SvgFontSize();

  factory SvgFontSize.absolute(double size) => _SvgFontSizeAbsolute(size);

  static const SvgFontSize inherit = _SvgFontSizeInherit();

  static const SvgFontSize larger = _SvgFontSizeRelative(1.2);

  static const SvgFontSize smaller = _SvgFontSizeRelative(1 / 1.2);

  static const double _med = 12;
  static const SvgFontSize medium = _SvgFontSizeAbsolute(_med);

  static const SvgFontSize small = _SvgFontSizeAbsolute(_med / 1.2);
  static const SvgFontSize x_small = _SvgFontSizeAbsolute(_med / (1.2 * 1.2));
  static const SvgFontSize xx_small =
      _SvgFontSizeAbsolute(_med / (1.2 * 1.2 * 1.2));

  static const SvgFontSize large = _SvgFontSizeAbsolute(_med * 1.2);
  static const SvgFontSize x_large = _SvgFontSizeAbsolute(_med * 1.2 * 1.2);
  static const SvgFontSize xx_large =
      _SvgFontSizeAbsolute(_med * 1.2 * 1.2 * 1.2);

  SvgFontSize orInherit(SvgFontSize ancestor);

  double toSI() {
    assert(false);
    return 12.0;
  }
}

class _SvgFontSizeAbsolute extends SvgFontSize {
  final double size;

  const _SvgFontSizeAbsolute(this.size);

  @override
  SvgFontSize orInherit(SvgFontSize ancestor) => this;

  @override
  double toSI() => size;
}

class _SvgFontSizeRelative extends SvgFontSize {
  final double scale;

  const _SvgFontSizeRelative(this.scale);

  @override
  SvgFontSize orInherit(SvgFontSize ancestor) {
    if (ancestor is _SvgFontSizeAbsolute) {
      return _SvgFontSizeAbsolute(ancestor.size * scale);
    } else {
      assert(false);
      return SvgFontSize.medium;
    }
  }
}

class _SvgFontSizeInherit extends SvgFontSize {
  const _SvgFontSizeInherit();

  @override
  SvgFontSize orInherit(SvgFontSize ancestor) => ancestor;
}

///
/// Color as SVG knows it, plus alpha in the high-order byte (in case we
/// encounter an SVG file with an (invalid) eight-character hex value).
///
abstract class SvgColor {
  const SvgColor();

  ///
  /// Create a normal, explicit color from an 0xaarrggbb value.
  ///
  factory SvgColor.value(int value) => SvgValueColor(value);

  ///
  /// Create the "inherit" color, which means "inherit from parent"
  ///
  static const SvgColor inherit = _SvgInheritColor._p();

  ///
  /// The "none" color, which means "do not paint"
  ///
  static const SvgColor none = _SvgNoneColor._p();

  ///
  /// Create the "currentColor" color, which means "paint with the color given
  /// to the ScalableImage's parent".
  ///
  static const SvgColor currentColor = _SvgCurrentColor._p();

  static const SvgColor white = SvgValueColor(0xffffffff);

  SvgColor orInherit(SvgColor ancestor, Map<String, SvgNode>? idLookup) => this;

  SIColor toSIColor(
      int? alpha, SvgColor cascadedCurrentColor, RectT Function() userSpace);

  static SvgColor reference(String id) => _SvgColorReference(id);
}

class SvgValueColor extends SvgColor {
  final int _value;
  const SvgValueColor(this._value);

  @override
  SIColor toSIColor(
      int? alpha, SvgColor cascadedCurrentColor, RectT Function() userSpace) {
    if (alpha == null) {
      return SIValueColor(_value);
    } else {
      return SIValueColor((_value & 0xffffff) | (alpha << 24));
    }
  }

  @override
  String toString() =>
      'SvgValueColor(#${_value.toRadixString(16).padLeft(6, "0")})';
}

class _SvgInheritColor extends SvgColor {
  const _SvgInheritColor._p();

  @override
  SvgColor orInherit(SvgColor ancestor, Map<String, SvgNode>? idLookup) =>
      ancestor;

  @override
  SIColor toSIColor(int? alpha, SvgColor cascadedCurrentColor,
          RectT Function() userSpace) =>
      throw StateError('Internal error: color inheritance');
}

class _SvgNoneColor extends SvgColor {
  const _SvgNoneColor._p();

  @override
  SIColor toSIColor(int? alpha, SvgColor cascadedCurrentColor,
          RectT Function() userSpace) =>
      SIColor.none;
}

class _SvgCurrentColor extends SvgColor {
  const _SvgCurrentColor._p();

  @override
  SIColor toSIColor(
      int? alpha, SvgColor cascadedCurrentColor, RectT Function() userSpace) {
    if (cascadedCurrentColor is _SvgCurrentColor) {
      return SIColor.currentColor;
    } else {
      return cascadedCurrentColor.toSIColor(
          alpha, const SvgValueColor(0), userSpace);
    }
  }
}

class _SvgColorReference extends SvgColor {
  final String id;

  _SvgColorReference(this.id);

  @override
  SvgColor orInherit(SvgColor ancestor, Map<String, SvgNode>? idLookup) {
    if (idLookup == null) {
      return this; // We'll resolve it later
    } else {
      final n = idLookup[id];
      if (n is! SvgGradientNode) {
        throw ParseError('Gradient $id not found');
      }
      return n.gradient;
    }
  }

  @override
  SIColor toSIColor(int? alpha, SvgColor cascadedCurrentColor,
          RectT Function() userSpace) =>
      throw StateError('Internal error: color inheritance');
}

class SvgGradientStop {
  final double offset;
  final SvgColor color; // But not a gradient!
  final int alpha;

  SvgGradientStop(this.offset, this.color, this.alpha) {
    if (color is SvgGradientColor) {
      throw StateError('Internal error:  Gradient stop cannot be gradient');
    }
  }
}

abstract class SvgGradientColor extends SvgColor {
  final bool? objectBoundingBox;
  List<SvgGradientStop>? stops;
  Affine? transform;
  SvgGradientColor? parent;
  final SIGradientSpreadMethod? spreadMethod;

  SvgGradientColor(this.objectBoundingBox, this.transform, this.spreadMethod);

  // Resolving getters:

  bool get objectBoundingBoxR =>
      objectBoundingBox ?? parent?.objectBoundingBoxR ?? true;

  List<SvgGradientStop> get stopsR => stops ?? parent?.stopsR ?? [];

  Affine? get transformR => transform ?? parent?.transformR;

  SIGradientSpreadMethod get spreadMethodR =>
      spreadMethod ?? parent?.spreadMethodR ?? SIGradientSpreadMethod.pad;

  void addStop(SvgGradientStop s) {
    final sl = stops ??= List<SvgGradientStop>.empty(growable: true);
    sl.add(s);
  }
}

class SvgCoordinate {
  final double _value;
  final bool isPercent;

  SvgCoordinate.value(this._value) : isPercent = false;
  SvgCoordinate.percent(this._value) : isPercent = true;

  double get value => isPercent ? (_value / 100) : _value;
}

class SvgLinearGradientColor extends SvgGradientColor {
  final SvgCoordinate? x1;
  final SvgCoordinate? y1;
  final SvgCoordinate? x2;
  final SvgCoordinate? y2;

  SvgLinearGradientColor? get linearParent {
    final p = parent;
    if (p is SvgLinearGradientColor) {
      return p;
    } else {
      return null;
    }
  }

  SvgLinearGradientColor(
      {required this.x1,
      required this.y1,
      required this.x2, // default 1
      required this.y2, // default 0
      required bool? objectBoundingBox, // default true
      required Affine? transform,
      required SIGradientSpreadMethod? spreadMethod})
      : super(objectBoundingBox, transform, spreadMethod);

  // Resolving getters:

  SvgCoordinate get x1R => x1 ?? linearParent?.x1R ?? SvgCoordinate.value(0.0);
  SvgCoordinate get y1R => y1 ?? linearParent?.y1R ?? SvgCoordinate.value(0.0);
  SvgCoordinate get x2R => x2 ?? linearParent?.x2R ?? SvgCoordinate.value(1.0);
  SvgCoordinate get y2R => y2 ?? linearParent?.y2R ?? SvgCoordinate.value(0.0);

  @override
  SIColor toSIColor(
      int? alpha, SvgColor cascadedCurrentColor, RectT Function() userSpace) {
    final stops = stopsR;
    final offsets = List<double>.generate(stops.length, (i) => stops[i].offset,
        growable: false);
    final colors = List<SIColor>.generate(
        stops.length,
        (i) => stops[i]
            .color
            .toSIColor(stops[i].alpha, cascadedCurrentColor, userSpace),
        growable: false);
    final obb = objectBoundingBoxR;
    late final RectT us = userSpace();
    double toDoubleX(SvgCoordinate c) {
      if (obb || !c.isPercent) {
        return c.value;
      } else {
        return us.left + us.width * c.value;
      }
    }

    double toDoubleY(SvgCoordinate c) {
      if (obb || !c.isPercent) {
        return c.value;
      } else {
        return us.top + us.height * c.value;
      }
    }

    return SILinearGradientColor(
        x1: toDoubleX(x1R),
        y1: toDoubleY(y1R),
        x2: toDoubleX(x2R),
        y2: toDoubleY(y2R),
        colors: colors,
        stops: offsets,
        objectBoundingBox: obb,
        spreadMethod: spreadMethodR,
        transform: transformR);
  }
}

class SvgRadialGradientColor extends SvgGradientColor {
  final SvgCoordinate? cx; // default 0.5
  final SvgCoordinate? cy; // default 0.5
  final SvgCoordinate? fx;
  final SvgCoordinate? fy;
  final SvgCoordinate? r; // default 0.5

  SvgRadialGradientColor? get radialParent {
    final p = parent;
    if (p is SvgRadialGradientColor) {
      return p;
    } else {
      return null;
    }
  }

  SvgRadialGradientColor(
      {required this.cx,
      required this.cy,
      required this.fx,
      required this.fy,
      required this.r,
      required bool? objectBoundingBox,
      required Affine? transform,
      required SIGradientSpreadMethod? spreadMethod})
      : super(objectBoundingBox, transform, spreadMethod);

  // Resolving getters:

  SvgCoordinate get cxR => cx ?? radialParent?.cxR ?? SvgCoordinate.value(0.5);
  SvgCoordinate get cyR => cy ?? radialParent?.cyR ?? SvgCoordinate.value(0.5);
  SvgCoordinate? get fxR => fx ?? radialParent?.fxR;
  SvgCoordinate? get fyR => fy ?? radialParent?.fyR;
  SvgCoordinate get rR => r ?? radialParent?.rR ?? SvgCoordinate.value(0.5);

  @override
  SIColor toSIColor(
      int? alpha, SvgColor cascadedCurrentColor, RectT Function() userSpace) {
    final stops = stopsR;
    final offsets = List<double>.generate(stops.length, (i) => stops[i].offset,
        growable: false);
    final colors = List<SIColor>.generate(
        stops.length,
        (i) => stops[i]
            .color
            .toSIColor(stops[i].alpha, cascadedCurrentColor, userSpace),
        growable: false);
    final obb = objectBoundingBoxR;
    late final RectT us = userSpace();
    double toDoubleX(SvgCoordinate c) {
      if (obb || !c.isPercent) {
        return c.value;
      } else {
        return us.left + us.width * c.value;
      }
    }

    double toDoubleY(SvgCoordinate c) {
      if (obb || !c.isPercent) {
        return c.value;
      } else {
        return us.top + us.height * c.value;
      }
    }

    final rr = rR;
    final double r;
    if (!obb && rr.isPercent) {
      final uw = us.width;
      final uh = us.height;
      r = rr.value * sqrt(uw * uw + uh + uh);
    } else {
      r = rr.value;
    }
    return SIRadialGradientColor(
        cx: toDoubleX(cxR),
        cy: toDoubleY(cyR),
        fx: toDoubleX(fxR ?? cxR),
        fy: toDoubleY(fyR ?? cyR),
        r: r,
        colors: colors,
        stops: offsets,
        objectBoundingBox: obb,
        spreadMethod: spreadMethodR,
        transform: transformR);
  }
}

class SvgSweepGradientColor extends SvgGradientColor {
  final double? cx; // default 0.5
  final double? cy; // default 0.5
  final double? startAngle;
  final double? endAngle;

  SvgSweepGradientColor? get sweepParent {
    final p = parent;
    if (p is SvgSweepGradientColor) {
      return p;
    } else {
      return null;
    }
  }

  SvgSweepGradientColor(
      {required this.cx,
      required this.cy,
      required this.startAngle,
      required this.endAngle,
      required bool? objectBoundingBox,
      required Affine? transform,
      required SIGradientSpreadMethod? spreadMethod})
      : super(objectBoundingBox, transform, spreadMethod);

  // Resolving getters:

  double get cxR => cx ?? sweepParent?.cxR ?? 0.5;
  double get cyR => cy ?? sweepParent?.cyR ?? 0.5;
  double get startAngleR => startAngle ?? sweepParent?.startAngleR ?? 0.0;
  double get endAngleR => endAngle ?? sweepParent?.endAngleR ?? 2 * pi;

  @override
  SIColor toSIColor(
      int? alpha, SvgColor cascadedCurrentColor, RectT Function() userSpace) {
    final stops = stopsR;
    final offsets = List<double>.generate(stops.length, (i) => stops[i].offset,
        growable: false);
    final colors = List<SIColor>.generate(
        stops.length,
        (i) => stops[i]
            .color
            .toSIColor(stops[i].alpha, cascadedCurrentColor, userSpace),
        growable: false);
    return SISweepGradientColor(
        cx: cxR,
        cy: cyR,
        startAngle: startAngleR,
        endAngle: endAngleR,
        colors: colors,
        stops: offsets,
        objectBoundingBox: objectBoundingBoxR,
        spreadMethod: spreadMethodR,
        transform: transformR);
  }
}

abstract class SvgFontWeight {
  const SvgFontWeight();

  static const SvgFontWeight w100 = _SvgFontWeightAbsolute(SIFontWeight.w100);
  static const SvgFontWeight w200 = _SvgFontWeightAbsolute(SIFontWeight.w200);
  static const SvgFontWeight w300 = _SvgFontWeightAbsolute(SIFontWeight.w300);
  static const SvgFontWeight w400 = _SvgFontWeightAbsolute(SIFontWeight.w400);
  static const SvgFontWeight w500 = _SvgFontWeightAbsolute(SIFontWeight.w500);
  static const SvgFontWeight w600 = _SvgFontWeightAbsolute(SIFontWeight.w600);
  static const SvgFontWeight w700 = _SvgFontWeightAbsolute(SIFontWeight.w700);
  static const SvgFontWeight w800 = _SvgFontWeightAbsolute(SIFontWeight.w800);
  static const SvgFontWeight w900 = _SvgFontWeightAbsolute(SIFontWeight.w900);
  static const SvgFontWeight bolder = _SvgFontWeightBolder();
  static const SvgFontWeight lighter = _SvgFontWeightLighter();
  static const SvgFontWeight inherit = _SvgFontWeightInherit();

  SvgFontWeight orInherit(SvgFontWeight ancestor);
  SIFontWeight toSI();
}

class _SvgFontWeightAbsolute extends SvgFontWeight {
  final SIFontWeight weight;
  const _SvgFontWeightAbsolute(this.weight);

  @override
  SvgFontWeight orInherit(SvgFontWeight ancestor) => this;

  @override
  SIFontWeight toSI() => weight;
}

class _SvgFontWeightBolder extends SvgFontWeight {
  const _SvgFontWeightBolder();

  @override
  SvgFontWeight orInherit(SvgFontWeight ancestor) {
    int i = ancestor.toSI().index;
    return _SvgFontWeightAbsolute(
        SIFontWeight.values[min(i + 1, SIFontWeight.values.length - 1)]);
  }

  @override
  SIFontWeight toSI() {
    assert(false);
    return SIFontWeight.w400;
  }
}

class _SvgFontWeightLighter extends SvgFontWeight {
  const _SvgFontWeightLighter();

  @override
  SvgFontWeight orInherit(SvgFontWeight ancestor) {
    int i = ancestor.toSI().index;
    return _SvgFontWeightAbsolute(SIFontWeight.values[max(i - 1, 0)]);
  }

  @override
  SIFontWeight toSI() {
    assert(false);
    return SIFontWeight.w400;
  }
}

class _SvgFontWeightInherit extends SvgFontWeight {
  const _SvgFontWeightInherit();

  @override
  SvgFontWeight orInherit(SvgFontWeight ancestor) => ancestor;

  @override
  SIFontWeight toSI() {
    assert(false);
    return SIFontWeight.w400;
  }
}

///
/// A boundary for calculating the user space.  A bit like PruningBounds, but
/// not using dependent on Flutter.
///
@immutable
class _SvgBoundary {
  final Point<double> a;
  final Point<double> b;
  final Point<double> c;
  final Point<double> d;

  _SvgBoundary(RectT rect)
      : a = Point(rect.left, rect.top),
        b = Point(rect.left + rect.width, rect.top),
        c = Point(rect.left + rect.width, rect.top + rect.height),
        d = Point(rect.left, rect.top + rect.height);

  const _SvgBoundary._p(this.a, this.b, this.c, this.d);

  RectT getBounds() {
    double left = min(min(a.x, b.x), min(c.x, d.x));
    double top = min(min(a.y, b.y), min(c.y, d.y));
    double right = max(max(a.x, b.x), max(c.x, d.x));
    double bottom = max(max(a.y, b.y), max(c.y, d.y));
    return Rectangle(left, top, right - left, bottom - top);
  }

  @override
  String toString() => '_SvgBoundary($a $b $c $d)';

  static Point<double> _tp(Point<double> p, Affine x) => x.transformed(p);

  _SvgBoundary transformed(Affine x) =>
      _SvgBoundary._p(_tp(a, x), _tp(b, x), _tp(c, x), _tp(d, x));
}
