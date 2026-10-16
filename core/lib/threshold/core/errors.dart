class InvalidZeroScalarException implements Exception {
  final String message;
  InvalidZeroScalarException(this.message);
  @override
  String toString() => 'InvalidZeroScalarException: $message';
}

class InvalidCoefficientsException implements Exception {
  final String message;
  InvalidCoefficientsException(this.message);
  @override
  String toString() => 'InvalidCoefficientsException: $message';
}

class InvalidMinSignersException implements Exception {
  final String message;
  InvalidMinSignersException(this.message);
  @override
  String toString() => 'InvalidMinSignersException: $message';
}

class InvalidMaxSignersException implements Exception {
  final String message;
  InvalidMaxSignersException(this.message);
  @override
  String toString() => 'InvalidMaxSignersException: $message';
}

class IncorrectNumberOfSharesException implements Exception {
  final String message;
  IncorrectNumberOfSharesException(this.message);
  @override
  String toString() => 'IncorrectNumberOfSharesException: $message';
}

class IncorrectNumberOfIdsException implements Exception {
  final String message;
  IncorrectNumberOfIdsException(this.message);
  @override
  String toString() => 'IncorrectNumberOfIdsException: $message';
}

class IncorrectNumberOfCommitmentsException implements Exception {
  final String message;
  IncorrectNumberOfCommitmentsException(this.message);
  @override
  String toString() => 'IncorrectNumberOfCommitmentsException: $message';
}

class DuplicatedIdentifierException implements Exception {
  final String message;
  DuplicatedIdentifierException(this.message);
  @override
  String toString() => 'DuplicatedIdentifierException: $message';
}

class InvalidCoefficientEncodingException implements Exception {
  final String message;
  InvalidCoefficientEncodingException(this.message);
  @override
  String toString() => 'InvalidCoefficientEncodingException: $message';
}

class InvalidSecretShareException implements Exception {
  final String message;
  InvalidSecretShareException(this.message);
  @override
  String toString() => 'InvalidSecretShareException: $message';
}

class InvalidCommitVectorException implements Exception {
  final String message;
  InvalidCommitVectorException(this.message);
  @override
  String toString() => 'InvalidCommitVectorException: $message';
}

class IncorrectNumberOfPackagesException implements Exception {
  final String message;
  IncorrectNumberOfPackagesException(this.message);
  @override
  String toString() => 'IncorrectNumberOfPackagesException: $message';
}

class IncorrectPackageException implements Exception {
  final String message;
  IncorrectPackageException(this.message);
  @override
  String toString() => 'IncorrectPackageException: $message';
}

class DKGNotSupportedException implements Exception {
  final String message;
  DKGNotSupportedException(this.message);
  @override
  String toString() => 'DKGNotSupportedException: $message';
}

class UnknownIdentifierException implements Exception {
  final String message;
  UnknownIdentifierException(this.message);
  @override
  String toString() => 'UnknownIdentifierException: $message';
}
