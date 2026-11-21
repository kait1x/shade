import 'dart:io';
import 'package:flutter/painting.dart';

ImageProvider avatarImage(String path) => FileImage(File(path));
