//
//  CheckRenderer.swift
//  ARMesh
//
//  Created by 安江洸希 on 2022/03/01.
//

import Metal
import MetalKit
import ARKit
import SwiftUI
import RealmSwift

class CheckRenderer {
    private let device: MTLDevice!
    private let library: MTLLibrary
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLComputePipelineState!
    private var viewportSize = CGSize()
    
    private let anchors: [ARMeshAnchor]
    var face_count: Int!
    
    private let calcuUniforms: [float4x4]
    private let depth: [depthPosition]
    private let calculateParameta: calculateParameta
    private let texImage: UIImage
    
    private var anchorUniformsBuffer: MetalBuffer<anchorUniforms>
    
    init(anchor: [ARMeshAnchor], calcuUniforms: [float4x4], depth: [depthPosition], calculateParameta: calculateParameta, texImage: UIImage) {
        
        self.anchors = anchor
        self.calcuUniforms = calcuUniforms
        self.depth = depth
        self.calculateParameta = calculateParameta
        self.texImage = texImage
        
        device = calculateParameta.device
        library = device.makeDefaultLibrary()!
        commandQueue = device.makeCommandQueue()!
        let function = library.makeFunction(name: calculateParameta.funcString)!
        pipeline = try! device.makeComputePipelineState(function: function)
        
        anchorUniformsBuffer = .init(device: device, count: 1, index: 9)
    }
    
    func drawRectResized(size: CGSize) {
        viewportSize = size
    }
    
    func calcu5(num: Int) -> SCNNode {
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        
        face_count = anchors[num].geometry.faces.count
        
        //main処理
        encoder.setBuffer(anchors[num].geometry.vertices.buffer, offset: 0, index: 0)
        encoder.setBuffer(anchors[num].geometry.normals.buffer, offset: 0, index: 1)
        encoder.setBuffer(anchors[num].geometry.faces.buffer, offset: 0, index: 2)
        
        //出力
        let texcoordsBuffer = device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride * face_count! * 3, options: [])
        let new_verticesBuffer = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride * face_count! * 3, options: [])
        let new_normalsBuffer = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride * face_count! * 3, options: [])
        let new_facesBuffer = device.makeBuffer(length: MemoryLayout<Int32>.stride * face_count! * 3, options: [])
        
        encoder.setBuffer(texcoordsBuffer, offset: 0, index: 3)
        encoder.setBuffer(new_verticesBuffer, offset: 0, index: 4)
        encoder.setBuffer(new_normalsBuffer, offset: 0, index: 5)
        encoder.setBuffer(new_facesBuffer, offset: 0, index: 6)
        
        //一時格納用
        let facecoordBuffer = device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride * face_count! * 3, options: [])
        encoder.setBuffer(facecoordBuffer, offset: 0, index: 7)
        
        //スクリーン座標変換用の行列が入ってる
        let calcuUniformsBuffer = device.makeBuffer(bytes: calcuUniforms, length: MemoryLayout<float4x4>.stride * calcuUniforms.count, options: [])
        encoder.setBuffer(calcuUniformsBuffer, offset: 0, index: 8)
        
        //計算に必要なその他
        anchorUniformsBuffer[0].transform = anchors[num].transform
        anchorUniformsBuffer[0].calcuCount = Int32(calcuUniforms.count)
        anchorUniformsBuffer[0].tate = Int32(calculateParameta.tate)
        anchorUniformsBuffer[0].yoko = Int32(calculateParameta.yoko)
        anchorUniformsBuffer[0].maxCount = Int32(anchors[num].geometry.faces.count)
        anchorUniformsBuffer[0].arrayCount = Int32(anchors[num].geometry.faces.count * 3)
        anchorUniformsBuffer[0].depthCount = Int32(128*96)
        anchorUniformsBuffer[0].screenWidth = Int32(calculateParameta.screenWidth)
        anchorUniformsBuffer[0].screenHeight = Int32(calculateParameta.screenHeight)
        anchorUniformsBuffer[0].picNumCount = Int32(1) //仮
        encoder.setBuffer(anchorUniformsBuffer)
        
        //深度情報
        let depthBuffer = device.makeBuffer(bytes: depth, length: MemoryLayout<depthPosition>.stride * 128*96 * calcuUniforms.count, options: [])
        encoder.setBuffer(depthBuffer, offset: 0, index: 10)
        
        let tryBuffer = device.makeBuffer(bytes: [0], length: MemoryLayout<Int>.stride, options: [])
        //device.makeBuffer(length: MemoryLayout<Int32>.stride * 128*96, options: [])
        encoder.setBuffer(tryBuffer, offset: 0, index: 11)
        
        let width = 1//32
        let threadsPerGroup = MTLSize(width: width, height: 1, depth: 1)
        let numThreadgroups = MTLSize(width: (anchors[num].geometry.faces.count + width - 1) / width, height: 1, depth: 1)
        encoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadsPerGroup)
        
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    
        let vertexData = Data(bytesNoCopy: new_verticesBuffer!.contents(), count: MemoryLayout<SIMD3<Float>>.stride * face_count! * 3, deallocator: .none)
        var vertexs = [SIMD3<Float>](repeating: SIMD3<Float>(0,0,0), count: face_count! * 3)
        vertexs = vertexData.withUnsafeBytes {
            Array(UnsafeBufferPointer<SIMD3<Float>>(start: $0, count: vertexData.count/MemoryLayout<SIMD3<Float>>.size))
        }
        
        let normalsData = Data(bytesNoCopy: new_normalsBuffer!.contents(), count: MemoryLayout<SIMD3<Float>>.stride * face_count! * 3, deallocator: .none)
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0,0,0), count: face_count! * 3)
        normals = normalsData.withUnsafeBytes {
            Array(UnsafeBufferPointer<SIMD3<Float>>(start: $0, count: normalsData.count/MemoryLayout<SIMD3<Float>>.size))
        }
        
        let facesData = Data(bytesNoCopy: new_facesBuffer!.contents(), count: MemoryLayout<Int32>.stride * face_count! * 3, deallocator: .none)
        var faces = [Int32](repeating: Int32(0), count: face_count! * 3)
        faces = facesData.withUnsafeBytes {
            Array(UnsafeBufferPointer<Int32>(start: $0, count: facesData.count/MemoryLayout<Int32>.size))
        }
        
        let texcoordsData = Data(bytesNoCopy: texcoordsBuffer!.contents(), count: MemoryLayout<SIMD2<Float>>.stride * face_count! * 3, deallocator: .none)
        var texcoords = [SIMD2<Float>](repeating: SIMD2<Float>(0,0), count: face_count! * 3)
        texcoords = texcoordsData.withUnsafeBytes {
            Array(UnsafeBufferPointer<SIMD2<Float>>(start: $0, count: texcoordsData.count/MemoryLayout<SIMD2<Float>>.size))
        }
        
        return build_model(vertexs: vertexs, normals: normals, faces: faces, texcoords: texcoords, count: face_count * 3)
    }
    
    func build_model(vertexs: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [Int32], texcoords: [SIMD2<Float>], count: Int) -> SCNNode {

        let vertexData = Data(bytes: vertexs, count: MemoryLayout<SIMD3<Float>>.size * vertexs.count)
        let normalData = Data(bytes: normals, count: MemoryLayout<SIMD3<Float>>.size * normals.count)
            
        let faces = faces
        let texcoords = texcoords
            
        let verticeSource = SCNGeometrySource(
            data: vertexData,
            semantic: SCNGeometrySource.Semantic.vertex,
            vectorCount: count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.size
        )
        let normalSource = SCNGeometrySource(
            data: normalData,
            semantic: SCNGeometrySource.Semantic.normal,
            vectorCount: count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: MemoryLayout<Float>.size * 3,
            dataStride: MemoryLayout<SIMD3<Float>>.size
        )
        let faceSource = SCNGeometryElement(indices: faces, primitiveType: .triangles)
        let textureCoordinates = SCNGeometrySource(textureCoordinates: texcoords)
        
        let nodeGeometry = SCNGeometry(sources: [verticeSource, normalSource, textureCoordinates], elements: [faceSource])
        nodeGeometry.firstMaterial?.diffuse.contents = texImage
        
        let node = SCNNode(geometry: nodeGeometry)
        
        return node
    }
}

