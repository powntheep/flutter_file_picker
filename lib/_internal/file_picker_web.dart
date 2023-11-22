import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/helpers.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

class FilePickerWeb extends FilePicker {
  late Element _target;
  final String _kFilePickerInputsDomId = '__file_picker_web-file-input';

  final int _readStreamChunkSize = 1000 * 1000; // 1 MB

  static final FilePickerWeb platform = FilePickerWeb._();

  FilePickerWeb._() {
    _target = _ensureInitialized(_kFilePickerInputsDomId);
  }

  static void registerWith(Registrar registrar) {
    FilePicker.platform = platform;
  }

  /// Initializes a DOM container where we can host input elements.
  Element _ensureInitialized(String id) {
    Element? target = querySelector('#$id');
    if (target == null) {
      createElementTag('flt-file-picker-inputs');
      final Element targetElement = createElementTag('flt-file-picker-inputs')
        ..id = id;

      querySelector('body')!.appendChild(targetElement);
      target = targetElement;
    }
    return target;
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    bool withData = true,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    if (type != FileType.custom && (allowedExtensions?.isNotEmpty ?? false)) {
      throw Exception(
          'You are setting a type [$type]. Custom extension filters are only allowed with FileType.custom, please change it or remove filters.');
    }

    final Completer<List<PlatformFile>?> filesCompleter =
        Completer<List<PlatformFile>?>();

    String accept = _fileType(type, allowedExtensions);

    print('accept: $accept');

    HTMLInputElement uploadInput =
        createElementTag('input') as HTMLInputElement;
    uploadInput.draggable = true;
    uploadInput.multiple = allowMultiple;
    uploadInput.accept = accept;
    uploadInput.type = 'file';
    uploadInput.style.display = 'none';

    bool changeEventTriggered = false;

    if (onFileLoading != null) {
      onFileLoading(FilePickerStatus.picking);
    }

    void changeEventListener(JSAny e) async {
      if (changeEventTriggered) {
        return;
      }
      changeEventTriggered = true;

      final FileList files = uploadInput.files!;
      final List<PlatformFile> pickedFiles = [];

      void addPickedFile(
        File file,
        Uint8List? bytes,
        String? path,
        Stream<List<int>>? readStream,
      ) {
        pickedFiles.add(PlatformFile(
          name: file.name,
          path: path,
          size: bytes != null ? bytes.length : file.size,
          bytes: bytes,
          readStream: readStream,
        ));

        if (pickedFiles.length >= files.length) {
          if (onFileLoading != null) {
            onFileLoading(FilePickerStatus.done);
          }
          filesCompleter.complete(pickedFiles);
        }
      }

      for (var i = 0; i < files.length; i++) {
        final file = files.item(i)!;
        if (withReadStream) {
          addPickedFile(file, null, null, _openFileReadStream(file));
          continue;
        }

        if (!withData) {
          final FileReader reader = FileReader();
          reader.onLoadEnd.listen((e) {
            addPickedFile(file, null, reader.result as String?, null);
          });
          reader.readAsDataURL(file);
          continue;
        }

        final syncCompleter = Completer<void>();
        final FileReader reader = FileReader();
        reader.onLoadEnd.listen((e) {
          try {
            final bytes = base64Decode(reader.result.toString().split(',').last);
            addPickedFile(file, bytes, null, null);
            syncCompleter.complete();
          } catch (e, stackTrace) {
            print(e);
            print(stackTrace);
            syncCompleter.completeError(e);
          }
        });
        reader.readAsDataURL(file);
        if (readSequential) {
          await syncCompleter.future;
        }
      }
    }

    void cancelledEventListener(JSObject _) {
      window.removeEventListener('focus', cancelledEventListener.toJS);

      // This listener is called before the input changed event,
      // and the `uploadInput.files` value is still null
      // Wait for results from js to dart
      Future.delayed(Duration(seconds: 1)).then((value) {
        if (!changeEventTriggered) {
          changeEventTriggered = true;
          filesCompleter.complete(null);
        }
      });
    }

    // uploadInput.onChange.listen((event) {
    //   changeEventListener(event as JSAny);
    // });
    uploadInput.addEventListener('change', changeEventListener.toJS);
    uploadInput.addEventListener('cancel', cancelledEventListener.toJS);

    // Listen focus event for cancelled
    window.addEventListener('focus', cancelledEventListener.toJS);

    //Add input element to the page body
    _target.replaceChildren(JSArray());
    _target.appendChild(uploadInput);
    uploadInput.click();

    final List<PlatformFile>? files = await filesCompleter.future;

    return files == null ? null : FilePickerResult(files);
  }

  static String _fileType(FileType type, List<String>? allowedExtensions) {
    switch (type) {
      case FileType.any:
        return '';

      case FileType.audio:
        return 'audio/*';

      case FileType.image:
        return 'image/*';

      case FileType.video:
        return 'video/*';

      case FileType.media:
        return 'video/*|image/*';

      case FileType.custom:
        return allowedExtensions!
            .fold('', (prev, next) => '${prev.isEmpty ? '' : '$prev,'} .$next');
    }
  }

  Stream<List<int>> _openFileReadStream(File file) async* {
    final reader = FileReader();

    int start = 0;
    while (start < file.size) {
      final end = start + _readStreamChunkSize > file.size
          ? file.size
          : start + _readStreamChunkSize;
      final blob = file.slice(start, end);
      reader.readAsArrayBuffer(blob);
      await reader.onLoadEnd.first;
      yield reader.result as List<int>;
      start += _readStreamChunkSize;
    }
  }
}
