/*完成バージョン！！*/
import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var latestResults: [Any] = []
    var lastRecognitionTime: Date?
    // Capture
    var bufferSize: CGSize = .zero
    var inferenceTime: CFTimeInterval = 0
    
    // カメラからの入出力をまとめるセッション
    private let session = AVCaptureSession()
    
    // UI/Layers
    @IBOutlet weak var previewView: UIView!
    var rootLayer: CALayer! = nil
    private var previewLayer: AVCaptureVideoPreviewLayer! = nil
    private var detectionLayer: CALayer! = nil
    private var inferenceTimeLayer: CALayer! = nil
    private var inferenceTimeBounds: CGRect! = nil
    
    // Vision
    private var requests = [VNRequest]()
    
    // Setup
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCapture()
        setupOutput()
        setupLayers()
        try? setupVision()
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
        //session.startRunning()
    }
    
    func setupCapture() {
        var deviceInput: AVCaptureDeviceInput!
        let videoDevice = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back).devices.first
        do {
            deviceInput = try AVCaptureDeviceInput(device: videoDevice!)
        } catch {
            print("Could not create video device input: \(error)")
            return
        }
        
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        
        guard session.canAddInput(deviceInput) else {
            print("Could not add video device input to the session")
            session.commitConfiguration()
            return
        }
        session.addInput(deviceInput)
        do {
            try videoDevice!.lockForConfiguration()
            let dimensions = CMVideoFormatDescriptionGetDimensions((videoDevice?.activeFormat.formatDescription)!)
            bufferSize.width = CGFloat(dimensions.width)
            bufferSize.height = CGFloat(dimensions.height)
            videoDevice!.unlockForConfiguration()
        } catch {
            print(error)
        }
        session.commitConfiguration()
    }
    
    func setupOutput() {
        let videoDataOutput = AVCaptureVideoDataOutput()
        let videoDataOutputQueue = DispatchQueue(label: "VideoDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        } else {
            print("Could not add video data output to the session")
            session.commitConfiguration()
            return
        }
    }
    
    func setupLayers() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        rootLayer = previewView.layer
        previewLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(previewLayer)
        
        inferenceTimeBounds = CGRect(x: rootLayer.frame.midX - 75, y: rootLayer.frame.maxY - 70, width: 150, height: 17)
        inferenceTimeLayer = createRectLayer(inferenceTimeBounds, [1,1,1,1])
        inferenceTimeLayer.cornerRadius = 7
        rootLayer.addSublayer(inferenceTimeLayer)
        
        detectionLayer = CALayer()
        detectionLayer.bounds = CGRect(x: 0.0,
                                       y: 0.0,
                                       width: bufferSize.width,
                                       height: bufferSize.height)
        detectionLayer.position = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)
        rootLayer.addSublayer(detectionLayer)
        
        let xScale: CGFloat = rootLayer.bounds.size.width / bufferSize.height
        let yScale: CGFloat = rootLayer.bounds.size.height / bufferSize.width
        
        let scale = fmax(xScale, yScale)
        
        // Rotate the layer into screen orientation and scale and mirror
        detectionLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(.pi / 2.0)).scaledBy(x: scale, y: -scale))
        // Center the layer
        detectionLayer.position = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)
    }
    
    // Reference: https://qiita.com/orimomo/items/a60d981ecaba5ce70293
    func setupVision() throws {
        // Load the model
        guard let modelURL = Bundle.main.url(forResource: "yolov5", withExtension: "mlmodelc") else {
            throw NSError(domain: "ViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model file is missing"])
        }
        
        do {
            let visionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
            let objectRecognition = VNCoreMLRequest(model: visionModel, completionHandler: { (request, error) in
                DispatchQueue.main.async(execute: {
                    // Handle the results
                    if let results = request.results {
                        // Draw the results
                        self.drawResults(results)
                        
                        // Capture and save the image
                        if let sampleBuffer = self.lastSampleBuffer {
                            self.captureAndSaveImage(from: sampleBuffer)
                        }
                    }
                })
            })
            self.requests = [objectRecognition]
        } catch let error as NSError {
            print("Model loading went wrong: \(error)")
        }
    }
    
    var lastSampleBuffer: CMSampleBuffer?
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        //ここの秒数を変えたら、撮影間隔が変わる
        
        if let lastRecognitionTime = lastRecognitionTime, Date().timeIntervalSince(lastRecognitionTime) < 0.2 {
            return
        }
        
        lastSampleBuffer = sampleBuffer
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            let start = CACurrentMediaTime()
            try imageRequestHandler.perform(self.requests)
            inferenceTime = (CACurrentMediaTime() - start)
            
            // Store the latest results
            if let results = self.requests.first?.results {
                latestResults = results
            }
            
            lastRecognitionTime = Date()
        } catch {
            print(error)
        }
    }
    
    
    func captureAndSaveImage(from sampleBuffer: CMSampleBuffer) {
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let context = CIContext()
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                let image = UIImage(cgImage: cgImage)
                
                // Save the image to the photo library if there are latest results
                if !latestResults.isEmpty {
                    // Upload the image using a webhook
                    uploadImage(image)
                }
            }
        }
    }
    
    func uploadImage(_ image: UIImage) {
        // Webhookのエンドポイントとパラメーターに適したリクエストの作成
    //https://webhook.site/#!/46784ce6-4a38-435d-9a87-dda9e7dd5010/be90dfe6-edad-493b-89fe-2640401239b7/1
        // URLはここを変更
        let url = URL(string: "https://webhook.site/46784ce6-4a38-435d-9a87-dda9e7dd5010")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        // 画像データをリクエストに追加
        let imageData = image.jpegData(compressionQuality: 0.8)!
        let boundary = "Boundary-\(UUID().uuidString)"
        let contentType = "multipart/form-data; boundary=\(boundary)"
        
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        // リクエストの送信
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            if let error = error {
                print("Error uploading image: \(error)")
            } else if let data = data {
                // レスポンスの処理
                // アップロードが成功した場合は、ここで適切な処理を実行してください
                print("Image uploaded successfully")
            }
        }
        task.resume()
    }
    
    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            print("Error saving image: \(error)")
        } else {
            print("Image saved successfully")
        }
    }
    
    func drawResults(_ results: [Any]) {
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        detectionLayer.sublayers = nil // Clear previous detections from detectionLayer
        inferenceTimeLayer.sublayers = nil
        for observation in results where observation is VNRecognizedObjectObservation {
            guard let objectObservation = observation as? VNRecognizedObjectObservation else {
                continue
            }
            
            let topLabelObservation = objectObservation.labels[0]
            print(topLabelObservation.identifier)
            
            // Rotate the bounding box into screen orientation
            let boundingBox = CGRect(origin: CGPoint(x:1.0-objectObservation.boundingBox.origin.y-objectObservation.boundingBox.size.height, y:objectObservation.boundingBox.origin.x), size: CGSize(width:objectObservation.boundingBox.size.height,height:objectObservation.boundingBox.size.width))
            
            let objectBounds = VNImageRectForNormalizedRect(boundingBox, Int(bufferSize.width), Int(bufferSize.height))
            
            let shapeLayer = createRectLayer(objectBounds, colors[topLabelObservation.identifier]!)
            
            let formattedString = NSMutableAttributedString(string: String(format: "\(topLabelObservation.identifier)\n %.1f%% ", topLabelObservation.confidence*100).capitalized)
            
            let textLayer = createDetectionTextLayer(objectBounds, formattedString)
            shapeLayer.addSublayer(textLayer)
            detectionLayer.addSublayer(shapeLayer)
        }
        
        let formattedInferenceTimeString = NSMutableAttributedString(string: String(format: "Inference time: %.1f ms ", inferenceTime*1000))
        let inferenceTimeTextLayer = createInferenceTimeTextLayer(inferenceTimeBounds, formattedInferenceTimeString)
        inferenceTimeLayer.addSublayer(inferenceTimeTextLayer)
        
        CATransaction.commit()
    }
    
    // Clean up capture setup
    func teardownAVCapture() {
        previewLayer.removeFromSuperlayer()
        previewLayer = nil
    }
}

