import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:excel/excel.dart';

class SheetManager {
  static const String sheetFileName = 'results.xlsx';

  // Get the path to the shared sheet
  static Future<String?> getSheetPath() async {
    final Directory? directory = await getExternalStorageDirectory();
    if (directory != null) {
      return '${directory.path}/$sheetFileName';
    }
    return null;
  }

  // Append data to the sheet
  static Future<void> appendToSheet(
      String regNo, String partAMarks, String partBMarks, String totalMarks) async {
    final filePath = await getSheetPath();
    if (filePath != null) {
      File file = File(filePath);
      Excel excel;
      if (await file.exists()) {
        var bytes = file.readAsBytesSync();
        excel = Excel.decodeBytes(bytes);
      } else {
        excel = Excel.createExcel(); // Create if doesn't exist
      }

      Sheet sheetObject = excel['Sheet1'];
      sheetObject.appendRow([regNo, partAMarks, partBMarks, totalMarks]);

      final fileBytes = excel.encode();
      if (fileBytes != null) {
        await file.writeAsBytes(fileBytes);
      }
    }
  }

  // Open the sheet to view it
  static Future<void> viewSheet() async {
    final filePath = await getSheetPath();
    if (filePath != null && await File(filePath).exists()) {
      OpenFile.open(filePath);
    }
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  _ScanPageState createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  CameraController? _cameraController;
  late TextRecognizer textRecognizer;
  String registeredNo = "";
  String partAMarks = "";
  String partBMarks = "";
  String grandTotal = "";
  XFile? capturedImage;
  bool isCameraActive = false;
  bool isProcessing = false;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _initializeTextRecognizer();
    _initCamera();
  }

  void _initializeTextRecognizer() {
    textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isNotEmpty) {
      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.high,
      );
      await _cameraController?.initialize();
      await _cameraController?.setExposureMode(ExposureMode.auto);
      await _cameraController?.setFocusMode(FocusMode.auto);

      setState(() {
        isCameraActive = true;
      });
    }
  }

  Future<void> _scanImage() async {
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      try {
        final imageFile = await _cameraController!.takePicture();
        await _processImage(imageFile);
      } catch (e) {
        print('Error capturing image: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error capturing image. Please try again.')),
        );
      }
    }
  }

  Future<void> _pickImageFromGallery() async {
    try {
      final pickedFile = await _picker.pickImage(source: ImageSource.gallery);
      if (pickedFile != null) {
        await _processImage(XFile(pickedFile.path));
      }
    } catch (e) {
      print('Error picking image from gallery: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error picking image. Please try again.')),
      );
    }
  }

  void _extractDetails(String scannedText) {
    try {
      final regNumberPattern = RegExp(r'Registered No\W*(\S+)', caseSensitive: false);
      final partATotalPattern = RegExp(r'Part-A Total\W*(\d+)', caseSensitive: false);
      final partBTotalPattern = RegExp(r'Part-B Total\W*(\d+)', caseSensitive: false);

      setState(() {
        final regNumberMatch = regNumberPattern.firstMatch(scannedText);
        final partAMatch = partATotalPattern.firstMatch(scannedText);
        final partBMatch = partBTotalPattern.firstMatch(scannedText);

        registeredNo = regNumberMatch?.group(1) ?? "Not Found";
        partAMarks = partAMatch?.group(1) ?? "0";
        partBMarks = partBMatch?.group(1) ?? "0";

        int partA = int.tryParse(partAMarks) ?? 0;
        int partB = int.tryParse(partBMarks) ?? 0;
        grandTotal = (partA + partB).toString();
      });

      // Append the extracted data to the shared Excel sheet
      SheetManager.appendToSheet(registeredNo, partAMarks, partBMarks, grandTotal);
    } catch (e) {
      print('Error extracting details: $e');
      setState(() {
        registeredNo = "Error";
        partAMarks = "Error";
        partBMarks = "Error";
        grandTotal = "Error";
      });
    }
  }

  Future<void> _processImage(XFile imageFile) async {
    setState(() {
      isProcessing = true;
    });

    try {
      final inputImage = InputImage.fromFilePath(imageFile.path);
      final recognizedText = await textRecognizer.processImage(inputImage);

      _extractDetails(recognizedText.text); // Extract details after scanning
      setState(() {
        capturedImage = imageFile;
        isCameraActive = false;
      });
    } catch (e) {
      print('Error processing image: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error processing image. Please try again.')),
      );
    } finally {
      setState(() {
        isProcessing = false;
      });
    }
  }

  void _viewExcelFile() {
    // Use SheetManager to view the sheet
    SheetManager.viewSheet();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    textRecognizer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Exam Sheets'),
        actions: [
          IconButton(
            icon: const Icon(Icons.image),
            onPressed: _pickImageFromGallery,
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _viewExcelFile,
          ),
        ],
      ),
      body: Column(
        children: [
          if (isCameraActive && !isProcessing)
            Expanded(child: CameraPreview(_cameraController!)),
          if (!isCameraActive && capturedImage != null)
            Expanded(child: Image.file(File(capturedImage!.path), fit: BoxFit.contain)),
          if (!isCameraActive && capturedImage == null)
            const Expanded(child: Center(child: Text('No image captured.'))),
          if (isProcessing) const CircularProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                if (registeredNo.isNotEmpty) Text('Registered No: $registeredNo'),
                if (partAMarks.isNotEmpty) Text('Part-A Marks: $partAMarks'),
                if (partBMarks.isNotEmpty) Text('Part-B Marks: $partBMarks'),
                if (grandTotal.isNotEmpty) Text('Grand Total: $grandTotal'),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: isCameraActive && !isProcessing
          ? FloatingActionButton(
              onPressed: _scanImage,
              child: const Icon(Icons.camera),
            )
          : null,
    );
  }
}
