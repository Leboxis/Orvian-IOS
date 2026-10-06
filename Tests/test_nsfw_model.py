import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('convert_nsfw', ROOT / 'scripts/nsfw/convert_model.py')
conversion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(conversion)


class ModelConversionTests(unittest.TestCase):
    def test_softmax_is_inserted_before_classifier_without_changing_backbone(self):
        Model, MIL = conversion.model_types()
        model = Model.Model()
        block = model.mlProgram.functions['main'].block_specializations['CoreML6']
        block.operations.add(type='softmax').outputs.add(name='attention_probabilities')
        logits = block.operations.add(type='linear')
        output = logits.outputs.add(name='logits')
        output.type.tensorType.dataType = MIL.FLOAT32
        output.type.tensorType.rank = 2
        for size in (1, 2):
            output.type.tensorType.dimensions.add().constant.size = size
        classify = block.operations.add(type='classify')
        classify.inputs['probabilities'].arguments.add(name='logits')
        before = logits.SerializeToString()
        conversion.add_softmax(model)
        self.assertEqual([op.type for op in block.operations], ['softmax', 'linear', 'softmax', 'classify'])
        self.assertEqual(block.operations[1].SerializeToString(), before)
        softmax = block.operations[2]
        self.assertEqual(softmax.inputs['x'].arguments[0].name, 'logits')
        self.assertEqual(softmax.inputs['axis'].arguments[0].value.immediateValue.tensor.ints.values[0], -1)
        self.assertEqual(block.operations[3].inputs['probabilities'].arguments[0].name,
                         softmax.outputs[0].name)
        with self.assertRaises(ValueError):
            conversion.add_softmax(model)

    def test_unknown_program_fails_instead_of_silently_patching(self):
        Model, _ = conversion.model_types()
        with self.assertRaises(ValueError):
            conversion.add_softmax(Model.Model())


if __name__ == '__main__':
    unittest.main()
